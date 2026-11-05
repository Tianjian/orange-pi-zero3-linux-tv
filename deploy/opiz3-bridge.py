#!/usr/bin/env python3
"""DLNA bridge: gmediarender does discovery/SOAP; this runs the proven
hardware-decode -> 720p -> fbdevsink pipeline for the current URI."""
import html, os, re, signal, socket, subprocess, sys, time, urllib.request

def _local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    finally:
        s.close()

# gmediarender's UPnP HTTP server binds the LAN interface, not loopback.
SOAP = os.environ.get("OPIZ3_SOAP", f"http://{_local_ip()}:49494/upnp/control/rendertransport1")
HW = "hw:CARD=ahubhdmi,DEV=0"
LOG = "/tmp/opiz3-bridge.log"
child = None
ff_proc = None
cur_uri = None

def soap(action, body="<InstanceID>0</InstanceID>"):
    data = f'''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:{action} xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">{body}</u:{action}></s:Body>
</s:Envelope>'''.encode()
    req = urllib.request.Request(SOAP, data=data, headers={
        "Content-Type": 'text/xml; charset="utf-8"',
        "SOAPACTION": f'"urn:schemas-upnp-org:service:AVTransport:1#{action}"'})
    return urllib.request.urlopen(req, timeout=3).read().decode("utf-8", "replace")

def state():
    try:
        m = re.search(r"<CurrentTransportState>(.*?)</CurrentTransportState>", soap("GetTransportInfo"))
        return m.group(1) if m else "STOPPED"
    except Exception:
        return "STOPPED"

def uri():
    try:
        t = soap("GetMediaInfo")
        m = re.search(r"<CurrentURI>(.*?)</CurrentURI>", t, re.S)
        return html.unescape(m.group(1)) if m else ""
    except Exception:
        return ""

def start_child(u):
    global child, ff_proc, cur_uri
    log = open(LOG, "ab", buffering=0)
    log.write(("\n=== %s %s\n" % (time.strftime("%F %T"), u)).encode())
    # ffmpeg software-decodes to raw NV12 (handles fragmented MP4/HLS);
    # kmssink puts it directly on the VI overlay plane (no RGB conversion).
    ff = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", u, "-map", "0:v:0", "-an",
         "-f", "rawvideo", "-pix_fmt", "nv12", "-"],
        stdout=subprocess.PIPE, stderr=log, start_new_session=True)
    cmd = [
        "gst-launch-1.0", "-q",
        "fdsrc", "!",
        "rawvideoparse", "width=1280", "height=720",
        "format=nv12", "framerate=30/1", "!",
        "kmssink", "plane-id=31",
    ]
    child = subprocess.Popen(cmd, stdin=ff.stdout, stdout=log,
                             stderr=subprocess.STDOUT, start_new_session=True)
    ff.stdout.close()
    ff_proc = ff
    cur_uri = u

def stop_child():
    global child, ff_proc, cur_uri
    for p in (child, ff_proc):
        if p and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except Exception:
                pass
    for p in (child, ff_proc):
        if p and p.poll() is None:
            try:
                p.wait(timeout=2)
            except Exception:
                try: os.killpg(p.pid, signal.SIGKILL)
                except Exception: pass
    child = None
    ff_proc = None
    cur_uri = None

def on_term(*_):
    stop_child()
    sys.exit(0)

signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)

while True:
    st, u = state(), uri()
    if st == "PLAYING" and u and (cur_uri != u or child is None or child.poll() is not None):
        stop_child()
        start_child(u)
    elif st != "PLAYING" or not u:
        stop_child()
    time.sleep(0.5)
