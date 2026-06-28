import numpy as np
from PIL import Image

# Load baked normal map, decode normals
nm = np.array(Image.open('share-chrome-normal.png').convert('RGBA')).astype(np.float32)/255.0
a = nm[...,3]
N = nm[...,:3]*2-1
nrm = np.linalg.norm(N, axis=2, keepdims=True)+1e-6
N = N/nrm
Nx, Ny, Nz = N[...,0], N[...,1], N[...,2]

def chrome_env(y, x):
    # Contrasty chrome: bright cool sky, crisp dark horizon, warm bright floor.
    # Brighter highlights + deeper darks than the flat version, but the darks
    # keep it visible on white.
    skyTop=np.array([0.95,0.98,1.00]); skyBlue=np.array([0.30,0.50,0.85])
    horizonD=np.array([0.16,0.20,0.30]); groundWarm=np.array([0.50,0.44,0.36]); groundBright=np.array([1.00,0.92,0.78])
    def ss(e0,e1,v):
        t=np.clip((v-e0)/(e1-e0),0,1); return t*t*(3-2*t)
    sky=skyBlue+(skyTop-skyBlue)*ss(0.06,0.6,y)[...,None]
    ground=groundWarm+(groundBright-groundWarm)*ss(-0.1,-0.6,y)[...,None]
    env=np.where((y>=0)[...,None], sky, ground)
    band=ss(0.14,0.0,np.abs(y))           # crisp (not wide) dark horizon
    env=env+(horizonD-env)*band[...,None]
    streak=0.5+0.5*np.sin(x*9.0)
    env*= (0.96+0.04*streak)[...,None]
    return env

def render(roll, pitch, t=0.0):
    ndv=Nz
    Rx=2*ndv*Nx; Ry=2*ndv*Ny
    G=0.85                                 # stronger gain -> reflection sweeps more
    rx=Rx+roll*G+np.sin(t*0.5)*0.03
    ry=Ry+pitch*G+np.cos(t*0.4)*0.03
    env=chrome_env(np.clip(ry,-1.5,1.5), rx)
    # moving hot spot (sparkle)
    sunx=0.20+roll*0.7; suny=0.40+pitch*0.7
    sd=np.sqrt((rx-sunx)**2+(ry-suny)**2)
    hot=np.clip((0.22-sd)/0.22,0,1); hot=hot*hot*(3-2*hot)
    env+=hot[...,None]*1.0
    rim=np.clip((Nz-0.26)/(0.58-0.26),0,1); rim=rim*rim*(3-2*rim)
    env*= (0.30+0.70*rim)[...,None]
    env=(env-0.5)*1.30+0.5
    env=np.maximum(env, 0.16)               # hard floor: never near-black
    env=np.clip(env,0,1)
    # composite on WHITE card (worst case for visibility)
    bg=np.array([0.97,0.972,0.985])
    out=bg*(1-a[...,None])+env*a[...,None]
    return (np.clip(out,0,1)*255).astype(np.uint8)

tiles=[]
for roll,pitch,lbl in [(0.0,0.40,'rest'),(0.35,0.50,'R'),(-0.35,0.30,'L')]:
    img=render(roll,pitch)
    Image.fromarray(img).save(f'/tmp/sim_{lbl}.png')
print('done')
