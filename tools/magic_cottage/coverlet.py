"""Draw the woven coverlet as one textile, laid out from rear hem to front hem."""
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parents[2] / "build/magic-cottage-design/coverlet.jpg"


def textile():
    size = 1024
    yy, xx = np.mgrid[:size, :size]
    rng = np.random.default_rng(211)
    warp = 2.3 * np.sin(xx * math.pi / 2) + 1.8 * np.cos((xx + yy) * math.pi / 3)
    wear = 3 * np.sin(xx * .023 + np.sin(yy * .015)) + rng.normal(0, 2.1, (size, size))
    ground = np.array([118, 48, 54]) + (warp + wear)[:, :, None]
    panel = Image.fromarray(np.uint8(np.clip(ground, 0, 255)))
    pen = ImageDraw.Draw(panel)
    gold, ochre, rose = (190, 149, 91), (154, 108, 72), (149, 75, 71)

    def sprig(x, y, s, ink):
        pen.line([(x, y+s), (x, y-s)], fill=ink, width=2)
        for side in [-1, 1]:
            for h in [0, .49]:
                tip = (x+side*.56*s, y+(.13-h)*s)
                pen.polygon([(x,y+(.53-h)*s), (x+side*.41*s,y+(.42-h)*s), tip,
                             (x+side*.17*s,y+(.17-h)*s)], fill=ink)
        pen.polygon([(x,y-s*1.12),(x+.13*s,y-.83*s),(x,y-.62*s),(x-.13*s,y-.83*s)],fill=ink)

    for row in range(15):
        y = 24 + 67 * row
        for x in range(20 + 40*(row%2), size, 80):
            sprig(x, y, 10, rose)
    for y in [717, 943]:
        # Interlaced lozenges flanked by paired pinstripes, aligned through every fold.
        pen.rectangle((0,y-22,size,y+22), fill=(75,49,50))
        for d in [-29,-24,-19,19,24,29]:
            pen.line((0,y+d,size,y+d), fill=gold if abs(d)==24 else ochre, width=2)
        for x in range(-32,size+32,32):
            pen.line([(x-19,y),(x,y-14),(x+19,y),(x,y+14),(x-19,y)],fill=gold,width=2)
            pen.polygon([(x-4,y),(x,y-5),(x+4,y),(x,y+5)], fill=ochre)
    # An upright row of embroidered quatrefoils across the inside back.
    for x in range(112,950,100):
        y = 452
        pen.line([(x-29,y),(x,y-37),(x+29,y),(x,y+37),(x-29,y)],fill=ochre,width=3)
        sprig(x,y,19,gold)
    for x in [24,30,size-31,size-25]:
        pen.line((x,0,x,size),fill=ochre,width=2)
    # Break the stitches into weft like the ground yarn.
    cloth = np.asarray(panel).astype(float) + (1.8*np.sin(yy*math.pi/2)+rng.normal(0,1.5,(size,size)))[:,:,None]
    OUT.parent.mkdir(parents=True,exist_ok=True)
    Image.fromarray(np.uint8(np.clip(cloth,0,255))).save(OUT,quality=92,subsampling=0)


if __name__ == "__main__":
    textile()
