# v2 bake: same geometry recipe as bake_chrome_normal.py, but computed at 3x
# (was 2x) with proportionally scaled radii/sigmas, output at 2x (was 1.5x),
# and DITHERED 8-bit encoding to break quantization banding. Writes
# share-chrome-normal-v2.png; the v1 asset is untouched.
import numpy as np, cairosvg
from PIL import Image
from scipy.ndimage import distance_transform_edt, gaussian_filter, binary_erosion
from skimage.morphology import disk

SRC = 'chrome-add-me-on-yafa.svg'
W = 1316
H = int(W * 1730 / 1321)
K = 3                     # geometry scale (v1: 2)
HW, HH = W * K, H * K
OUT_W, OUT_H = W * 2, H * 2   # output scale (v1: 1.5)

SS = 2
cairosvg.svg2png(url=SRC, write_to='_mask_v2.png',
                 output_width=HW*SS, output_height=HH*SS, background_color='white')
m = np.array(Image.open('_mask_v2.png').convert('L').resize((HW, HH), Image.LANCZOS)).astype(np.float32)
raw = (np.clip((255.0 - m) / 255.0, 0, 1) > 0.5)

R_SCALE = K / 2.0                         # radii/sigmas scale vs the 2x bake
OUTLINE_R = int(round(15 * R_SCALE))      # same physical outline width as v1
eroded = binary_erosion(raw, structure=disk(OUTLINE_R))
solid = (raw & ~eroded).astype(np.float32)

d_in = distance_transform_edt(solid)
R = OUTLINE_R / 2.0
d_sm = gaussian_filter(d_in, sigma=1.6 * R_SCALE)
t = np.clip(d_sm / R, 0, 1)
dome = np.sqrt(np.clip(1 - (1 - t) ** 2, 0, 1))
height = gaussian_filter(dome * solid, sigma=1.3 * R_SCALE)

# gradient shrinks per-pixel as resolution grows -> compensate to keep the
# same physical steepness as v1 (3.3 at 2x)
gy, gx = np.gradient(height * 3.3 * R_SCALE)
nz = np.ones_like(height) * 0.38
nlen = np.sqrt(gx*gx + gy*gy + nz*nz) + 1e-6
nx, ny, nz = -gx/nlen, -gy/nlen, nz/nlen
nx = gaussian_filter(nx, sigma=1.6 * R_SCALE)
ny = gaussian_filter(ny, sigma=1.6 * R_SCALE)
nz = gaussian_filter(nz, sigma=1.6 * R_SCALE)
nlen = np.sqrt(nx*nx + ny*ny + nz*nz) + 1e-6
nx, ny, nz = nx/nlen, ny/nlen, nz/nlen
alpha = np.clip(gaussian_filter(solid, sigma=1.3 * R_SCALE), 0, 1)

def down(a):
    return np.array(Image.fromarray((np.clip((a+1)/2,0,1)*255).astype(np.uint8)).resize((OUT_W, OUT_H), Image.LANCZOS)).astype(np.float32)/255.0*2-1
nx = down(nx); ny = down(ny); nz = down(nz)
nlen = np.sqrt(nx*nx + ny*ny + nz*nz) + 1e-6
nx, ny, nz = nx/nlen, ny/nlen, nz/nlen
alpha = np.array(Image.fromarray((alpha*255).astype(np.uint8)).resize((OUT_W, OUT_H), Image.LANCZOS)).astype(np.float32)/255.0

# Dithered encode — but ONLY where the letterforms live. Dithering the
# empty background (alpha == 0, never read by the shader) is pure noise
# to the PNG compressor and ballooned the file 7x. Background pixels get
# a constant flat-normal encoding instead.
rng = np.random.default_rng(7)
covered = alpha > 0.001
def enc(v, flat):
    q = (v*0.5+0.5)*255 + rng.uniform(-0.5, 0.5, v.shape)
    q8 = np.clip(q, 0, 255).astype(np.uint8)
    q8[~covered] = flat
    return q8
out = np.zeros((OUT_H, OUT_W, 4), np.uint8)
out[..., 0] = enc(nx, 128); out[..., 1] = enc(ny, 128); out[..., 2] = enc(nz, 255)
out[..., 3] = np.clip(alpha*255, 0, 255).astype(np.uint8)
Image.fromarray(out, 'RGBA').save('share-chrome-normal-v2.png', optimize=True)
print('v2 normal map', out.shape)
