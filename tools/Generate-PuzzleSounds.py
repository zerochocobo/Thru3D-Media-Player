"""Generate original procedural puzzle cues. No external recordings or dependencies."""
from pathlib import Path
import math, random, struct, wave

ROOT=Path(__file__).resolve().parent.parent
OUTPUT=ROOT/'app/godot/audio/puzzle'
RATE=48000

def render(name,duration,synth,seed):
    rng=random.Random(seed); samples=[]; filtered=0.0
    for i in range(round(duration*RATE)):
        t=i/RATE; noise=rng.uniform(-1,1); filtered=filtered*0.75+noise*0.25
        attack=min(1,t/0.002); release=min(1,(duration-t)/0.018)
        value=math.tanh(synth(t,noise,filtered,rng))*attack*release
        samples.append(max(-32767,min(32767,round(value*32767))))
    OUTPUT.mkdir(parents=True,exist_ok=True)
    with wave.open(str(OUTPUT/(name+'.wav')),'wb') as stream:
        stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(RATE)
        stream.writeframes(struct.pack('<'+'h'*len(samples),*samples))
    return samples

def rotate(t,n,f,r):
    return 0.19*math.exp(-t*95)*(0.55*n+math.sin(math.tau*1730*t)*0.6+math.sin(math.tau*2410*t)*0.25)
def snap(t,n,f,r):
    body=math.sin(math.tau*(420*t-180*t*t))*math.exp(-t*30)
    wood=(math.sin(math.tau*1260*t)+0.35*math.sin(math.tau*1945*t))*math.exp(-t*65)
    return 0.27*body+0.16*wood+0.18*(n-f)*math.exp(-t*110)
def success(t,n,f,r):
    value=0.0
    for start,hz in [(0,523.25),(0.11,659.25),(0.22,783.99),(0.36,1046.5)]:
        age=t-start
        if age<0:continue
        envelope=min(1,age/0.006)*math.exp(-age*5.5)
        value+=0.15*envelope*(math.sin(math.tau*hz*age)+0.18*math.sin(math.tau*hz*2.76*age)*math.exp(-age*7))
    return value
def launch(t,n,f,r):
    x=t/0.42; swell=math.sin(math.pi*min(1,x))**0.8
    return swell*(0.25*(n-f)+0.06*math.sin(math.tau*(520*t+1700*t*t)))
def burst(t,n,f,r):
    thump=0.34*math.sin(math.tau*(95*t-50*t*t))*math.exp(-t*15)
    air=0.28*f*math.exp(-t*7)+0.13*(n-f)*math.exp(-t*28)
    crackle=(0.20*n if r.random()<0.018 else 0)*math.exp(-t*5)
    return thump+air+crackle

if __name__=='__main__':
    for name,duration,synth,seed in [('rotate',0.065,rotate,41),('snap',0.16,snap,42),('success',1.15,success,43),('launch',0.42,launch,44),('burst',0.65,burst,45)]:
        samples=render(name,duration,synth,seed)
        rms=math.sqrt(sum((v/32768)**2 for v in samples)/len(samples))
        print(f'{name}: {duration:.3f}s, peak={max(abs(v) for v in samples)/32768:.3f}, rms={rms:.3f}')
