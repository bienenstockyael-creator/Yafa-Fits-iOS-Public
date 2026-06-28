import numpy as np, cairosvg
from PIL import Image
from scipy.ndimage import distance_transform_edt, gaussian_filter, binary_erosion
from skimage.morphology import disk

SRC = 'chrome-add-me-on-yafa.svg'
W = 1316
H = int(W * 1730 / 1321)
# Compute geometry at 2x so thin strokes are wide enough for clean EDT normals
# (no dashing); downsample the finished normal map at the end.
HW = W * 2
HH = H * 2
# Output at 1.5x so iOS (which rasterises the colorEffect at display res) has
# extra pixels to downscale -> anti-aliased, smoother stroke edges.
OUT_W = int(W * 1.5)
OUT_H = int(H * 1.5)

# 1. Rasterize SVG fill -> clean AA alpha mask of the strokes (at 2x)
SS = 2
cairosvg.svg2png(url=SRC, write_to='_mask.png',
                 output_width=HW*SS, output_height=HH*SS, background_color='white')
m = np.array(Image.open('_mask.png').convert('L').resize((HW, HH), Image.LANCZOS)).astype(np.float32)
raw = (np.clip((255.0 - m) / 255.0, 0, 1) > 0.5)

# 1b. THIN OUTLINE: the SVG letters are solid bold fills, 2-4x heavier than
#     the thin frame/connector strokes. Replace each solid letter with a thin
#     OUTLINE of its contour (solid AND NOT eroded) at a width matching the
#     frame, so the chrome letters read as delicate hollow bubble letters
#     instead of fat blobs. Already-thin frames/connectors survive whole
#     (erosion empties them, so NOT-eroded keeps them). Thin strokes also let
#     the tube-dome complete -> rounder, less flat chrome.
OUTLINE_R = 15                                 # erosion radius @2x -> ~7.5px @1x (a touch heavier)
eroded = binary_erosion(raw, structure=disk(OUTLINE_R))
solid = (raw & ~eroded).astype(np.float32)

# 2. Distance transform -> rounded tube dome. R = half the outline thickness so
#    the dome COMPLETES across the stroke (full rounded cylinder = 3D, not flat).
d_in = distance_transform_edt(solid)
R = OUTLINE_R / 2.0
d_sm = gaussian_filter(d_in, sigma=1.6)
t = np.clip(d_sm / R, 0, 1)
dome = np.sqrt(np.clip(1 - (1 - t) ** 2, 0, 1))
height = gaussian_filter(dome * solid, sigma=1.3)

# 3. Surface normals (steep enough that tilting sweeps the environment)
gy, gx = np.gradient(height * 3.3)             # steeper -> normals sweep more env
nz = np.ones_like(height) * 0.38
nlen = np.sqrt(gx*gx + gy*gy + nz*nz) + 1e-6
nx, ny, nz = -gx/nlen, -gy/nlen, nz/nlen
# Smooth the normal field to kill EDT striping, then renormalise.
nx = gaussian_filter(nx, sigma=1.6)
ny = gaussian_filter(ny, sigma=1.6)
nz = gaussian_filter(nz, sigma=1.6)
nlen = np.sqrt(nx*nx + ny*ny + nz*nz) + 1e-6
nx, ny, nz = nx/nlen, ny/nlen, nz/nlen
alpha = np.clip(gaussian_filter(solid, sigma=1.3), 0, 1)   # AA edge (2x), softer

# 3b. Downsample the normal field + alpha from 2x to the output res, renorm.
def down(a):
    return np.array(Image.fromarray((np.clip((a+1)/2,0,1)*255).astype(np.uint8)).resize((OUT_W, OUT_H), Image.LANCZOS)).astype(np.float32)/255.0*2-1
nx = down(nx); ny = down(ny); nz = down(nz)
nlen = np.sqrt(nx*nx + ny*ny + nz*nz) + 1e-6
nx, ny, nz = nx/nlen, ny/nlen, nz/nlen
alpha = np.array(Image.fromarray((alpha*255).astype(np.uint8)).resize((OUT_W, OUT_H), Image.LANCZOS)).astype(np.float32)/255.0

# 4. Encode normal map: RGB = normal*0.5+0.5, A = coverage. PNG (lossless,
#    so the shader recovers accurate normals — webp would corrupt them).
out = np.zeros((OUT_H, OUT_W, 4), np.uint8)
out[..., 0] = np.clip((nx*0.5+0.5)*255, 0, 255).astype(np.uint8)
out[..., 1] = np.clip((ny*0.5+0.5)*255, 0, 255).astype(np.uint8)
out[..., 2] = np.clip((nz*0.5+0.5)*255, 0, 255).astype(np.uint8)
out[..., 3] = (alpha*255).astype(np.uint8)
Image.fromarray(out, 'RGBA').save('share-chrome-normal.png')
print('normal map', out.shape)
