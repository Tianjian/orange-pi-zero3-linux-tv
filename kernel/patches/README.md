# vendor 6.1 DE3.3 display experiments (GPL-2.0)

`0001-de33-display-fixes.patch` is generated from a vendor `linux-6.1`
tree (`6.1.31-sun50iw9`) while investigating H618 DE3.3 + cedrus + overlay.

It contains:

- treat `is_de33` like `is_de3` for VI format table, alpha, color encodings,
  and VI scaler scale-mode;
- DE3.3 CSC setup at `DE33_CCSC_BASE + channel*DE33_CH_SIZE`
  with 15-entry coefficient layout;
- fix VI scaler coefficient selection (vertical uses `vstep`, chroma uses
  `hsub/vsub`);
- write opaque `SUN50I_SCALER_VSU_GLB_ALPHA`.

These patches were used to get `videotestsrc ! NV12 ! kmssink plane-id=31`
working (CPU ~1%), but **are not used by the final DLNA demo**:
cedrus still fails on Bilibili phone streams at ~6 s, and DE3.3 scaler
downscaling still shows horizontal stripes. See `docs/19`.

Apply to the vendor kernel tree:

```bash
git -C linux-6.1 apply /path/to/0001-de33-display-fixes.patch
```

License: GPL-2.0 (kernel source).
