"""Water mask for Pax CorpInc3D's trees (pax_corpinc3d/config/water.png) from NASA's Blue Marble.

  python tools/gen_water.py <Blue Marble jpg> [out.png]

The provinces' map knows the seas only — the lakes (Ladoga, Onega, Baikal, the Great Lakes, the reservoirs) belong to
provinces, and forest.png's 0.2° cells took the trees right into them. Here every 0.05° (~5 km) says water or land:
dark and bluish in Blue Marble (June 2004) — water. 7200×3600, 1 bit, equirectangular like forest.png.
Needs Pillow and numpy.
"""
import sys

import numpy as np
from PIL import Image

W, H = 7200, 3600
Image.MAX_IMAGE_PIXELS = None


def main() -> None:
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "pax_corpinc3d/config/water.png"
    im = Image.open(src)
    im.draft("RGB", (W, H))
    rgb = np.asarray(im.convert("RGB").resize((W, H), Image.BILINEAR), dtype=np.float32)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    # Water: blue over red, not the green of forest, not bright (ice, cloud-free snow, salt flats).
    water = (b > r * 1.12) & (b > g * 0.95) & (lum < 90.0)
    Image.fromarray((water * 255).astype(np.uint8), "L").convert("1").save(out, optimize=True)
    print("%s: %d×%d, water %.1f%%" % (out, W, H, 100.0 * float(water.mean())))


if __name__ == "__main__":
    main()
