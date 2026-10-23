"""Remove leftover white background between/around hair strands in a cut-out sprite (white chips the cutout missed).
A pixel goes transparent when it is near-white and its neighbourhood is mostly hair, not cloth.
Sizes are tuned on a 1348x2252 sprite and scale with the image.
Usage: python3 defringe.py in.png out.png [--face y0:y1,x0:x1] [--fill-face-holes] [--preview p.png]
  --face             region never cleared (eyes and skin are light too), in pixels of in.png
  --fill-face-holes  also refill see-through holes inside --face with white (a cutout that punched out an eye white)"""
import argparse, numpy as np
from PIL import Image
from scipy import ndimage

ap = argparse.ArgumentParser()
ap.add_argument("src"); ap.add_argument("out")
ap.add_argument("--face"); ap.add_argument("--fill-face-holes", action="store_true"); ap.add_argument("--preview")
args = ap.parse_args()

im = np.asarray(Image.open(args.src).convert("RGBA")).copy()
area = im.shape[0] * im.shape[1] / (1348 * 2252)                     # scale for pixel-count thresholds
kernel = max(5, round(25 * area ** 0.5))
rgb = im[..., :3].astype(np.int16); alpha = im[..., 3] > 0
lo, spread = rgb.min(axis=2), rgb.max(axis=2) - rgb.min(axis=2)
white = alpha & (lo > 178) & (spread < 65)
hair = alpha & (rgb[..., 0] - rgb[..., 2] > 90) & (rgb[..., 0] > 150)
mean = lambda m: ndimage.uniform_filter(m.astype(float), kernel, mode="constant")
sizes = lambda lab: np.bincount(lab.ravel())                          # pixels per connected component

# keep only the big hair masses: orange embroidery, irises and the sunflower are small separate blobs
hl, _ = ndimage.label(ndimage.binary_closing(hair, iterations=2))
hs = sizes(hl); hs[0] = 0
hair &= hs[hl] > 40000 * area
hair_frac, open_frac = mean(hair), mean(~alpha)
# white chips: small connected white bits sitting in hair (or on the hair/transparent edge), not big cloth areas
lab, _ = ndimage.label(white)
size = sizes(lab)[lab]
small = size < 800 * area
cloth_frac = mean(white & (size >= 3000 * area))                     # big white = clothes
kill = white & small & (hair_frac > 0.35) & (cloth_frac < 0.15)
kill |= white & small & (open_frac > 0.2) & (hair_frac > 0.2)
kill = ndimage.binary_dilation(kill, iterations=1) & (lo > 165) & (spread < 75) & alpha   # take the soft rim too
gold = (rgb[..., 0] > 170) & (rgb[..., 1] > 130) & (rgb[..., 1] - rgb[..., 2] > 70)    # tassels / sunflowers keep their highlights
kill &= ~ndimage.binary_dilation(gold, iterations=5)

face = np.zeros_like(alpha)
if args.face:
    (y0, y1), (x0, x1) = [map(int, r.split(":")) for r in args.face.split(",")]
    face[y0:y1, x0:x1] = True
kill &= ~face
if args.fill_face_holes:   # refill see-through holes (and their soft rims) that are enclosed and inside the face
    see = im[..., 3] < 255
    holes, _ = ndimage.label(see)
    edge = np.unique(np.concatenate([holes[0], holes[-1], holes[:, 0], holes[:, -1]]))
    fill = see & face & ~np.isin(holes, edge)
    a = im[..., 3:4].astype(float) / 255
    im[..., :3] = np.where(fill[..., None], im[..., :3] * a + np.array([250, 248, 246]) * (1 - a), im[..., :3]).astype(np.uint8)
    im[fill, 3] = 255
im[kill, 3] = 0
Image.fromarray(im).save(args.out)
print("cleared", int(kill.sum()), "px")
if args.preview:
    show = Image.new("RGBA", im.shape[1::-1], (30, 40, 60, 255)); show.alpha_composite(Image.open(args.src).convert("RGBA"))
    s = np.asarray(show).copy(); s[kill] = (255, 0, 255, 255)
    Image.fromarray(s).convert("RGB").resize((im.shape[1] // 2, im.shape[0] // 2)).save(args.preview)
