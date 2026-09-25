"""Generate the iOS app icon sizes from one geometric camera mark."""

import json
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"


def make_master() -> Image.Image:
    size = 1024
    image = Image.new("RGB", (size, size), "#101B1D")
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((178, 260, 846, 774), radius=146, fill="#C6F4D5")
    draw.rounded_rectangle((280, 213, 516, 300), radius=42, fill="#C6F4D5")
    draw.ellipse((341, 337, 683, 679), fill="#101B1D")
    draw.ellipse((400, 396, 624, 620), fill="#C6F4D5")
    draw.ellipse((450, 446, 574, 570), fill="#101B1D")
    draw.ellipse((726, 323, 790, 387), fill="#101B1D")
    return image


def main() -> None:
    with (ICON_DIR / "Contents.json").open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    master = make_master()
    for entry in manifest["images"]:
        filename = entry["filename"]
        points = float(entry["size"].split("x")[0])
        scale = float(entry.get("scale", "1x").removesuffix("x"))
        pixels = round(points * scale)
        master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(ICON_DIR / filename)


if __name__ == "__main__":
    main()
