"""Remove leftover white background between/around hair strands in the pixel sprites (white chips the cutout missed).
A pixel goes transparent when it is near-white and its neighbourhood is mostly hair, not cloth or skin.
Usage: python3 defringe.py in.png out.png [preview.png]"""
import sys, numpy as np
from PIL import Image
from scipy import ndimage

src, out = sys.argv[1:3]
im = np.asarray(Image.open(src).convert("RGBA")).copy()
rgb = im[..., :3].astype(np.int16); alpha = im[..., 3] > 0
lo, spread = rgb.min(axis=2), rgb.max(axis=2) - rgb.min(axis=2)
white = alpha & (lo > 178) & (spread < 65)
hair = alpha & (rgb[..., 0] - rgb[..., 2] > 90) & (rgb[..., 0] > 150)
# keep only the big hair masses: orange embroidery, irises and the sunflower are small separate blobs
hl, hn = ndimage.label(ndimage.binary_closing(hair, iterations=2))
hsize = ndimage.sum(np.ones_like(hl), hl, index=np.arange(hn + 1)); hsize[0] = 0
hair &= hsize[hl] > 40000
k = np.ones((25, 25)) / 625
hair_frac = ndimage.convolve(hair.astype(float), k, mode="constant")
open_frac = ndimage.convolve((~alpha).astype(float), k, mode="constant")
# white chips: small connected white bits sitting in hair (or on the hair/transparent edge), not big cloth areas
lab, n = ndimage.label(white)
size = ndimage.sum(np.ones_like(lab), lab, index=np.arange(n + 1))
small = size[lab] < 800
cloth_frac = ndimage.convolve((white & (size[lab] >= 3000)).astype(float), k, mode="constant")   # big white = clothes
kill = white & small & (hair_frac > 0.35) & (cloth_frac < 0.15)
kill |= white & small & (open_frac > 0.2) & (hair_frac > 0.2)
kill = ndimage.binary_dilation(kill, iterations=1) & (lo > 165) & (spread < 75) & alpha   # take the soft rim too
gold = (rgb[..., 0] > 170) & (rgb[..., 1] > 130) & (rgb[..., 1] - rgb[..., 2] > 70)    # tassels / sunflowers keep their highlights
kill &= ~ndimage.binary_dilation(gold, iterations=5)
# the face (fixed box for these sprites) is never cleared; see-through holes inside it get refilled
face = np.zeros_like(alpha); face[300:640, 440:800] = True
kill &= ~face
# the original cutout punched the white of one eye out: refill see-through holes (and their soft rims) inside the face
see = im[..., 3] < 255
holes, _ = ndimage.label(see)
edge = set(np.unique(np.concatenate([holes[0], holes[-1], holes[:, 0], holes[:, -1]])))
fill = see & face & ~np.isin(holes, list(edge))
a = im[..., 3:4].astype(float) / 255
im[..., :3] = np.where(fill[..., None], im[..., :3] * a + np.array([250, 248, 246]) * (1 - a), im[..., :3]).astype(np.uint8)
im[fill, 3] = 255
im[kill, 3] = 0
Image.fromarray(im).save(out)
print("cleared", int(kill.sum()), "px")
if len(sys.argv) > 3:
    show = Image.new("RGBA", im.shape[1::-1], (30, 40, 60, 255)); show.alpha_composite(Image.open(src).convert("RGBA"))
    s = np.asarray(show).copy(); s[kill] = (255, 0, 255, 255)
    Image.fromarray(s).convert("RGB").resize((im.shape[1] // 2, im.shape[0] // 2)).save(sys.argv[3])
