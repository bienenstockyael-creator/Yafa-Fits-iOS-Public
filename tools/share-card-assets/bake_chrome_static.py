import numpy as np
from PIL import Image
import sim_chrome as s
def ss(e0,e1,v):
    t=np.clip((v-e0)/(e1-e0),0,1); return t*t*(3-2*t)
def light_env(y,x):
    skyTop=np.array([0.97,0.98,1.00]); skyBlue=np.array([0.62,0.74,0.92])
    horizonD=np.array([0.50,0.55,0.64]); groundWarm=np.array([0.70,0.66,0.60]); groundBright=np.array([0.97,0.94,0.88])
    sky=skyBlue+(skyTop-skyBlue)*ss(0.06,0.6,y)[...,None]
    ground=groundWarm+(groundBright-groundWarm)*ss(-0.1,-0.6,y)[...,None]
    env=np.where((y>=0)[...,None],sky,ground)
    env=env+(horizonD-env)*ss(0.14,0.0,np.abs(y))[...,None]
    env*=(0.97+0.03*(0.5+0.5*np.sin(x*9.0)))[...,None]
    return env
def render_rgba(roll,pitch):
    Nx,Ny,Nz,a=s.Nx,s.Ny,s.Nz,s.a
    ndv=Nz; Rx=2*ndv*Nx; Ry=2*ndv*Ny
    rx=Rx+roll*0.50; ry=Ry+pitch*0.50
    env=light_env(np.clip(ry,-1.5,1.5),rx)
    sd=np.sqrt((rx-(0.20+roll*0.5))**2+(ry-(0.40+pitch*0.5))**2)
    hot=np.clip((0.22-sd)/0.22,0,1); hot=hot*hot*(3-2*hot)
    env+=hot[...,None]*0.6
    rim=np.clip((Nz-0.26)/(0.58-0.26),0,1); rim=rim*rim*(3-2*rim)
    env*=(0.45+0.55*rim)[...,None]
    env=(env-0.5)*1.12+0.5; env=np.maximum(env,0.32); env=np.clip(env,0,1)
    r=np.zeros(env.shape[:2]+(4,),np.uint8); r[...,:3]=(env*255).astype(np.uint8); r[...,3]=(a*255).astype(np.uint8)
    return r
Image.fromarray(render_rgba(0.0,0.30)).save('chrome-static.png')
print('light static saved')
