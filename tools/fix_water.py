"""The trees' water mask made right (pax_corpinc3d/config/water.png after gen_water.py): Blue Marble's colours took the
murky Baltic — the Gulf of Finland, the skerries round Turku — for land, and the trees stood in the sea there. Here a
0.05° cell is water where any map says so: the mask itself, or at least 40 % of the cell at the sea's level of the
relief (textures/earth/height.png, R·256+G = 0 — the coast the player sees on the 3D ground) or in the sea of the
provinces' map (textures/earth/borders_ids.png, id 0).

    pip install pillow numpy
    python tools/fix_water.py [pax_corpinc3d folder]
"""
import os
import sys

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None


def share(m, H, W):
    """The share of True in each cell of an H×W grid, from 4×4 samples per cell."""
    mh, mw = m.shape
    acc = np.zeros((H, W), np.float32)
    for sy in range(4):
        for sx in range(4):
            ys = ((np.arange(H) + (sy + 0.5) / 4) / H * mh).astype(int).clip(0, mh - 1)
            xs = ((np.arange(W) + (sx + 0.5) / 4) / W * mw).astype(int).clip(0, mw - 1)
            acc += m[np.ix_(ys, xs)]
    return acc / 16.0


def main():
    mod = sys.argv[1] if len(sys.argv) > 1 else "pax_corpinc3d"
    path = os.path.join(mod, "config", "water.png")
    w = np.array(Image.open(path).convert("L")) > 127
    H, W = w.shape
    h = np.array(Image.open(os.path.join(mod, "textures", "earth", "height.png")))
    sea_h = (h[..., 0].astype(np.int32) * 256 + h[..., 1]) == 0
    ids = np.array(Image.open(os.path.join(mod, "textures", "earth", "borders_ids.png")))
    sea_i = (ids[..., 0].astype(np.int32) + ids[..., 1].astype(np.int32) * 256) == 0
    out = w | (share(sea_h, H, W) >= 0.4) | (share(sea_i, H, W) >= 0.4)
    print("water share %.3f -> %.3f" % (w.mean(), out.mean()))
    Image.fromarray((out * 255).astype(np.uint8), "L").save(path, optimize=True)


if __name__ == "__main__":
    main()
