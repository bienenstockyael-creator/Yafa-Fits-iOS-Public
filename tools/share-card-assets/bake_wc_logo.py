# Bakes the World Cup "26" knockout silhouette used by the World Cup share-card
# template (ShareCardComposer). The SVG is a single filled "26" shape; we keep
# its alpha (counters are already transparent from the SVG fill rule) and set
# RGB to white so the app can tint it per country variant via
# `.renderingMode(.template)`.
#
# Output: wc-logo.png  ->  copy to
#   YaelFits/Resources/Assets.xcassets/wc-logo.imageset/wc-logo.png
#
# Run from this directory:  python3 bake_wc_logo.py

import cairosvg
import numpy as np
from PIL import Image

cairosvg.svg2png(url='fifa-world-cup-26.svg', write_to='_wc26.png',
                 output_width=1620, output_height=2500)
a = np.array(Image.open('_wc26.png').convert('RGBA'))
out = a.copy()
out[..., 0] = 255
out[..., 1] = 255
out[..., 2] = 255  # white rgb (template tint ignores rgb, uses alpha)
Image.fromarray(out, 'RGBA').save('wc-logo.png')
print('wc-logo.png written', out.shape)
