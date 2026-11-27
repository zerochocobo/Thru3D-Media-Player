"""Synthesize the cottage's original mono point-source effects. No sample library is required."""
from pathlib import Path
import wave
import zlib

import numpy as np

OUT = Path(__file__).resolve().parents[2] / "app/godot/environments/magic_cottage/sounds"
RATE = 24000


class Cue:
    def __init__(self, name, seconds):
        self.name = name
        self.rng = np.random.default_rng(zlib.crc32(name.encode()))
        self.samples = np.zeros(round(RATE * seconds))

    def add(self, at, sound):
        start = round(at * RATE)
        count = min(len(sound), len(self.samples) - start)
        if count > 0:
            self.samples[start:start + count] += sound[:count]

    def tone(self, at, length, note, level=.6, instrument="glass", end=None, attack=.012):
        t = np.arange(round(RATE * length)) / RATE
        u = t / length
        end = note if end is None else end
        phase = 2 * np.pi * (note * t + (end-note) * t * u * .5)
        partials = {
            "glass": [(1, 1), (2.73, .22), (4.14, .08)],
            "bronze": [(1, .85), (2.41, .45), (3.8, .22), (5.35, .11)],
            "string": [(1, .75), (2, .30), (3, .14), (5, .09)],
            "wood": [(1, 1), (2.76, .32), (4.9, .13)],
            "breath": [(1, .80), (1.008, .24), (2, .09)],
        }[instrument]
        value = sum(weight*np.sin(ratio*phase)*np.exp(-u*(2.2+.7*ratio)) for ratio, weight in partials)
        envelope = np.minimum(t / attack, 1) * np.minimum((1-u)*20, 1)
        self.add(at, level * value * envelope)

    def air(self, at, length, low, high, level=.4, attack=.05, decay=2.4):
        n = round(RATE * length)
        t = np.arange(n) / RATE
        freq = np.fft.rfftfreq(n, 1/RATE)
        spectrum = np.fft.rfft(self.rng.normal(size=n))
        band = (1-np.exp(-(freq/low)**4))*np.exp(-(freq/high)**4)
        grain = np.fft.irfft(spectrum*band, n=n)
        grain /= max(.01, np.sqrt(np.mean(grain**2))*3)
        env = np.minimum(t/attack, 1) * np.minimum((length-t)*30, 1) * np.exp(-decay*t/length)
        self.add(at, level * grain * env)

    def melody(self, notes, interval, length, instrument, start=.03, level=.48):
        for i, note in enumerate(notes):
            self.tone(start+i*interval, length, note, level, instrument)

    def save(self):
        dry = self.samples.copy()
        for delay, gain in [(.031,.13),(.069,.085),(.121,.053)]:
            offset = round(RATE * delay)
            self.samples[offset:] += dry[:-offset]*gain
        fade = min(len(self.samples)//4, round(.026*RATE))
        self.samples[-fade:] *= np.linspace(1, 0, fade)
        peak = max(abs(self.samples))
        self.samples *= min(1.65, .76/peak)
        with wave.open(str(OUT/(self.name+".wav")), "wb") as sink:
            sink.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
            sink.writeframes((self.samples*32767).astype("<i2").tobytes())


def scenes():
    c = Cue("weightless", 2.75)
    c.air(0, 2.55, 80, 650, .7, .46)
    for i, n in enumerate([146.83,220,293.66]): c.tone(.10+i*.27,1.8,n*.62,.53,"breath",n,.31)
    c.save()
    c = Cue("watcher", 2.2)
    c.air(0, 1.45, 75, 480, .8, .25)
    c.tone(.31,1.43,114,.62,"string",77,.18)
    c.air(1.05,.47,420,1450,.39,.14)
    c.save()
    c = Cue("collapse", 2.15)
    c.tone(0,1.0,392,.67,"breath",77,.19)
    c.air(.18,.74,160,1900,.60,.25)
    c.tone(.91,.85,91,.90,"wood",51)
    c.air(.93,1.,65,920,.82,.012)
    c.save()
    c = Cue("aurora", 3.25)
    for i,n in enumerate([220,329.63,415.3,493.88]): c.tone(i*.27,2.3,n,.36,"breath",n*1.012,.64)
    c.save()
    c = Cue("moths", 2.25)
    for i in range(12):
        c.air(.10+i*.14,.11,430,2900,.30,.025)
        if i%3==0: c.tone(.10+i*.14,.45,620+i*16,.22,"glass")
    c.save()
    c = Cue("frost", 2.16)
    for i in range(13):
        c.tone(i*.1,.43,700+c.rng.uniform(0,970),.21,"glass")
        c.air(i*.1,.065,1100,3900,.23,.003)
    c.save()
    c = Cue("meteors", 2.25)
    for i in range(4):
        c.air(.11+i*.37,.66,480,2800,.55,.11)
        c.tone(.13+i*.37,.53,720-i*45,.33,"breath",220-i*11)
    c.save()
    c = Cue("backward", 2.67)
    c.melody([220,261.63,329.63,440],.36,1.03,"bronze")
    c.samples=c.samples[::-1].copy()
    c.save()
    c = Cue("ivy", 2.33)
    for i in range(10):
        c.air(.04+i*.16,.23,310,1650,.44,.04)
        c.tone(.05+i*.16,.18,172+i*16,.24,"wood")
    c.save()
    c = Cue("lanterns", 3.)
    c.melody([293.66,440,369.99,493.88,587.33],.36,1.15,"bronze",level=.42)
    c.save()


def wands():
    c = Cue("fire_cast", .46)
    c.air(0,.36,120,2300,1.05,.018)
    c.tone(0,.28,142,.68,"wood",74)
    c.save()
    c = Cue("fire_air", 1.25)
    c.air(0,1.2,220,1760,.69,.13,.30)
    c.tone(.035,.91,192,.30,"breath",290,.23)
    c.save()
    c = Cue("fire_impact", .79)
    c.air(0,.72,65,1450,1.1,.004)
    c.tone(0,.50,119,.9,"wood",63)
    for i in range(7): c.air(.08+i*.053,.047,1200,4300,.36,.002)
    c.save()
    c = Cue("ice_bloom", 1.03)
    c.melody([932,1244,1480,1864],.085,.48,"glass",level=.35)
    c.air(0,.51,990,3400,.42,.04)
    c.save()
    c = Cue("forked_thunder", .76)
    for at,level in [(0,1.),(.087,.72),(.18,.46)]:
        c.air(at,.18,300,4800,level,.002,4)
    c.tone(.07,.57,105,.68,"breath",57)
    c.save()
    c = Cue("bronze_bell", 1.7)
    c.tone(0,1.60,392,.81,"bronze",attack=.004)
    c.air(0,.035,910,2900,.37,.002)
    c.save()
    c = Cue("rose_bloom", 1.14)
    for i in range(7): c.air(i*.095,.18,440,2300,.32,.018)
    c.melody([294,370,440],.17,.53,"string",start=.18,level=.33)
    c.save()
    c = Cue("star_ink", .72)
    c.tone(0,.61,784,.6,"glass")
    c.air(0,.15,1400,3300,.28,.025)
    c.save()
    c = Cue("page_vortex", 1.39)
    for i in range(9): c.air(.04+i*.115,.165,560,3600,.62,.035)
    c.air(.02,1.3,90,700,.55,.27)
    c.save()
    for name,notes in [("gate_open",[196,293.66]),("gate_link",[293.66,440,587.33])]:
        c = Cue(name,1.28)
        c.melody(notes,.185,.80,"bronze",level=.45)
        c.air(.03,.61,230,1300,.52,.16)
        c.save()
    for name,notes in [("koi_call",[392,523.25]),("koi_swim",[659.25,523.25,392])]:
        c = Cue(name,.82)
        for i,n in enumerate(notes): c.tone(.045+i*.12,.31,n*.71,.6,"breath",n,.015)
        c.air(0,.45,200,1530,.26,.08)
        c.save()
    for name,start,end in [("moon_cast",440,745),("moon_return",745,392)]:
        c = Cue(name,.68)
        c.tone(0,.58,start,.54,"string",end,.045)
        c.air(.015,.40,550,2670,.55,.063)
        c.save()


def encounters():
    c=Cue("window_open",1.25)
    c.air(0,.8,210,1280,.72,.21)
    c.melody([698.46,466.16],.155,.66,"glass",start=.21)
    c.save()
    for name,low,high,interval in [("bat_wing",155,1600,.115),("scarab_wing",620,3200,.072),("raven_wing",410,2650,.175)]:
        c=Cue(name,1.06)
        for i in range(round(.8/interval)):
            c.air(i*interval,interval*.84,low,high,.73 if i%2==0 else .44,.012)
            if name=="scarab_wing": c.tone(i*interval,.06,510+(i%2)*170,.18,"bronze")
        c.save()
    for name,notes,inst in [("repelled",[587,880],"glass"),("escaped",[247,165],"wood"),
                            ("ward_win",[392,494,587,784],"bronze"),("ward_lost",[293.66,246.94,196],"string"),
                            ("attune",[293.66,440,587.33],"glass"),("coffer",[330,392,494],"string")]:
        c=Cue(name,1.8 if name.startswith("ward_") else 1.05)
        c.melody(notes,.16 if name.startswith("ward_") else .09,.77,inst)
        c.save()
    c=Cue("ingredient",.49)
    c.tone(.01,.32,233,.72,"breath",409)
    c.air(.025,.14,290,1650,.45,.01)
    c.save()
    # A steady trickle with scattered droplets; the room repeats it while the ewer pours.
    c=Cue("pour",1.6)
    c.air(0,1.6,380,2400,.55,.18,.6)
    for i in range(16): c.tone(.05+i*.093+c.rng.uniform(0,.05),.09,c.rng.uniform(900,1700),.10,"glass")
    c.save()
    c=Cue("brew_fail",1.33)
    c.air(0,.88,75,820,1.,.016)
    c.tone(0,.52,138,.7,"wood",55)
    for i in range(3): c.air(.2+.25*i,.21,180,1130,.48,.023)
    c.save()


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    scenes()
    wands()
    encounters()
