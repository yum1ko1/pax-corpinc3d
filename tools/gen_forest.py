"""Forest map for Pax CorpInc3D's trees (pax_corpinc3d/config/forest.png) from NASA's pictures of the Earth.

  python tools/gen_forest.py <Blue Marble jpg> <Black Marble jpg> [out.png]

Blue Marble Next Generation (world.200406.3x21600x10800.jpg, June 2004, true colour) says where the land is dark
green — forest; Black Marble 2016 (night lights) takes the trees out of the cities. The result: 1800×900 grey PNG,
equirectangular like the game's maps (x = (lon+180)/360·W, y = (90−lat)/180·H), the value — the share of forest in
the cell, 0..255. Needs Pillow and numpy.
"""
import sys

import numpy as np
from PIL import Image

W, H = 1800, 900          # 0.2° a cell
POOL = 3                  # each cell is the share over POOL×POOL pixels of the colour picture
Image.MAX_IMAGE_PIXELS = None


def load(path: str, w: int, h: int) -> np.ndarray:
    im = Image.open(path)
    im.draft("RGB", (w, h))   # the JPEG decoder shrinks it by itself: no 700 MB of pixels
    return np.asarray(im.convert("RGB").resize((w, h), Image.BILINEAR), dtype=np.float32)


def forest(rgb: np.ndarray) -> np.ndarray:
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    # Forest in Blue Marble (June) is the darkest land: lum ~25–45, green at least as red (boreal forest with its
    # lakes is a little brown), much greener than blue. Fields and meadows are green too but lighter (lum 55–65),
    # steppe and desert tan and light, tundra and water bluish, ice white.
    shade = np.clip((52.0 - lum) / 10.0, 0.0, 1.0)
    return (shade * ((g >= r * 0.88) & (g > b * 1.5) & (lum > 8))).astype(np.float32)


def main() -> None:
    blue, black = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else "pax_corpinc3d/config/forest.png"
    rgb = load(blue, W * POOL, H * POOL)
    f = forest(rgb).reshape(H, POOL, W, POOL).mean(axis=(1, 3))
    lights = load(black, W, H).mean(axis=2)
    f *= np.clip(1.0 - (lights - 60.0) / 80.0, 0.0, 1.0)   # bright night lights — a city, no forest
    Image.fromarray(np.round(f * 255.0).astype(np.uint8), "L").save(out, optimize=True)
    print("%s: %d×%d, forest cells %.1f%%" % (out, W, H, 100.0 * float((f > 0.3).mean())))


if __name__ == "__main__":
    main()
