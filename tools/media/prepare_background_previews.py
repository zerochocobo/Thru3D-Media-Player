"""Generate small perspective previews from the bundled equirectangular originals."""
from pathlib import Path
from PIL import Image
import numpy as np

root = Path(__file__).resolve().parents[2] / "app/godot/backgrounds"
output = root / "previews"
output.mkdir(exist_ok=True)
for name, filename in [("belfast", "belfast_sunset_puresky.jpg"), ("morning", "kloppenheim_06_puresky.jpg"), ("night", "eso0932a.jpg")]:
    image = Image.open(root / filename).convert("RGB")
    image.thumbnail((2048, 1024), Image.Resampling.LANCZOS)
    source = np.asarray(image)
    xx, yy = np.meshgrid(np.linspace(-1, 1, 512), np.linspace(-1, 1, 288))
    xx *= np.tan(np.deg2rad(55))
    yy *= np.tan(np.deg2rad(55)) * 288 / 512
    longitude = np.arctan2(xx, 1)
    latitude = np.arctan2(-yy, np.sqrt(1 + xx * xx))
    u = ((longitude / (2 * np.pi) + 0.5) * source.shape[1]).astype(int) % source.shape[1]
    v = np.clip(((0.5 - latitude / np.pi) * source.shape[0]).astype(int), 0, source.shape[0] - 1)
    Image.fromarray(source[v, u]).save(output / f"{name}.jpg", quality=90, optimize=True)
print(output)
