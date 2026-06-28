# Share-card asset bakes

Reproducible bakes for the generated assets used by the share cards. These are
the source of truth for a few binary assets that otherwise can't be regenerated
from the repo.

## Requirements

```bash
pip install cairosvg pillow numpy scipy scikit-image
```

Run every script **from this directory** (paths are relative).

## Assets

### 1. Chrome "add me on yafa" wordmark — normal map (iOS)

The live chrome wordmark on the profile share card is a Metal reflection shader
(`YaelFits/Shaders/Chrome.metal`) that reflects a procedural environment off a
baked **normal map** of the letterforms. The shader is live; this map is just
the geometry.

```bash
python3 bake_chrome_normal.py
```

- **Source:** `chrome-add-me-on-yafa.svg`
- **Output:** `share-chrome-normal.png`  →  copy to `YaelFits/Resources/share-chrome-normal.png`
- Letters are reduced to a thin even **outline** of the bold source glyphs, the
  tube is domed via a distance transform, normals are smoothed, and the map is
  rendered at 1.5× so iOS downscales it to smooth, anti-aliased edges.
- `sim_chrome.py` is a numpy port of `Chrome.metal` to preview tilt states
  without a device — invaluable for tuning. **Keep its env/tuning values in
  sync with `Chrome.metal`.**

### 2. Chrome wordmark — static still (web OG)

The OG link-preview image can't run WebGL, so it uses a baked still.

```bash
python3 bake_chrome_normal.py   # produces share-chrome-normal.png first
python3 bake_chrome_static.py
```

- **Output:** `chrome-static.png`  →  copy to the web repo `Yael-Fits/public/chrome-static.png`
- Uses the lighter "web" environment values (matches the web `CHROME_FRAG`).

### 3. World Cup "26" knockout (iOS)

```bash
python3 bake_wc_logo.py
```

- **Source:** `fifa-world-cup-26.svg`
- **Output:** `wc-logo.png`  →  copy to `YaelFits/Resources/Assets.xcassets/wc-logo.imageset/wc-logo.png`
- A tintable silhouette (white RGB + the "26" alpha); the app tints it per
  country variant via `.renderingMode(.template)`.
- ⚠️ The "26" mark is FIFA IP — see the in-app World Cup template before any
  public release.
