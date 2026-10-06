"""Forest map for Pax CorpInc3D's trees (pax_corpinc3d/config/forest.png) from real land cover — Overture Maps'
base/land_cover (ESA WorldCover 10 m, vectorised; ODbL / CC BY 4.0), read from its public S3 bucket.

    pip install pyarrow numpy pillow
    python tools/gen_forest_cover.py [out.png] [release]

The old map (gen_forest.py) took the darkest green of Blue Marble for forest: shaded mountain slopes and dark fields
got trees. Here each 0.2° cell's share of forest is the area of the «forest» and «mangrove» polygons in it over the
cell: the polygons are small (~200 m — the 10 m raster vectorised), so their boxes stand for their areas; only
the detailed polygons are used (cartography.min_zoom ≥ 8), the generalised ones of the small scales would count twice.
Only the classes, the zooms and the boxes are read — not the geometry (a few GB of the 109). 1800×900 grey PNG,
equirectangular (x = (lon+180)/360·W, y = (90−lat)/180·H), the value — the share 0..255, as before.
"""
import sys
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import pyarrow.fs as pfs
import pyarrow.parquet as pq
from PIL import Image

W, H = 1800, 900
FOREST = {"forest", "mangrove"}
FILL = 0.6        # a polygon's share of its box (irregular patches): the same for every class


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "pax_corpinc3d/config/forest.png"
    release = sys.argv[2] if len(sys.argv) > 2 else "2026-09-23.1"
    fs = pfs.S3FileSystem(anonymous=True, region="us-west-2")
    root = f"overturemaps-us-west-2/release/{release}/theme=base/type=land_cover/"
    files = sorted(f.path for f in fs.get_file_info(pfs.FileSelector(root)) if f.path.endswith(".parquet"))
    forest = np.zeros((H, W), np.float64)
    cover = np.zeros((H, W), np.float64)

    def one(path: str):
        tb = pq.ParquetFile(path, filesystem=fs).read(columns=["subtype", "cartography", "bbox"])
        mz = tb.column("cartography").combine_chunks().field("min_zoom").to_numpy(zero_copy_only=False)
        sub = np.array(tb.column("subtype").to_pylist(), dtype=object)
        bb = tb.column("bbox").combine_chunks()
        x0 = bb.field("xmin").to_numpy(); x1 = bb.field("xmax").to_numpy()
        y0 = bb.field("ymin").to_numpy(); y1 = bb.field("ymax").to_numpy()
        keep = mz >= 8
        cx = (x0 + x1) * 0.5
        cy = (y0 + y1) * 0.5
        area = (x1 - x0) * np.cos(np.radians(cy)) * (y1 - y0) * FILL      # degrees², like the cells below
        gx = np.clip(((cx + 180.0) / 360.0 * W).astype(int), 0, W - 1)
        gy = np.clip(((90.0 - cy) / 180.0 * H).astype(int), 0, H - 1)
        isf = np.isin(sub, list(FOREST))
        f = np.zeros(H * W)
        c = np.zeros(H * W)
        np.add.at(c, (gy * W + gx)[keep], area[keep])
        np.add.at(f, (gy * W + gx)[keep & isf], area[keep & isf])
        return f.reshape(H, W), c.reshape(H, W)

    done = 0
    with ThreadPoolExecutor(8) as ex:
        for f, c in ex.map(one, files):
            forest += f
            cover += c
            done += 1
            if done % 16 == 0:
                print("  %d / %d files" % (done, len(files)), flush=True)
    # Over the cell's whole area (degrees² × cos φ): the classes WorldCover leaves out of the polygons (grass, mostly)
    # are not forest — dividing by the covered area alone made the steppe look wooded.
    lat = 90.0 - (np.arange(H) + 0.5) / H * 180.0
    cell = (360.0 / W) * (180.0 / H) * np.cos(np.radians(lat))[:, None]
    share = np.clip(forest / np.maximum(cell, 1e-12), 0.0, 1.0)
    Image.fromarray((share * 255.0 + 0.5).astype(np.uint8), "L").save(out, optimize=True)
    print("forest map %s: forest in %.1f %% of the cells" % (out, 100.0 * (share > 0.2).mean()))


if __name__ == "__main__":
    main()
