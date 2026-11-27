"""Assemble the ten real spell captures from render_spells.gd into a labelled plate."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
INPUT = ROOT / "build/magic-cottage-design/wand-gallery"
OUTPUT = ROOT / "docs/design/magic-cottage/wand-magic.jpg"


def main():
    labels = ["炉心飞火", "六枝雪印", "分岔惊雷", "回声铜铃", "墙上蔷薇",
              "织星笔", "藏书旋风", "双扉引蝶", "游鱼引灵", "归杖月轮"]
    plate = Image.new("RGB", (856, 5*260+12), "#201d26")
    caption = ImageDraw.Draw(plate)
    font = ImageFont.truetype("msyh.ttc", 21)
    for i, label in enumerate(labels):
        filename = "fire-flight.jpg" if i == 0 else f"wand-{10+i}.jpg"
        with Image.open(INPUT / filename) as shot:
            w, h = shot.size
            top = .24 if i == 3 else .16
            crop = shot.crop((w*.13, h*top, w*.87, h*(top+.62)))
            x, y = 12 + (i % 2)*420, 12 + (i // 2)*260
            plate.paste(crop.resize((412, 215), Image.Resampling.LANCZOS), (x, y))
            caption.text((x+3, y+220), label, font=font, fill="#efe1bd")
    plate.save(OUTPUT, quality=91)


if __name__ == "__main__":
    main()
