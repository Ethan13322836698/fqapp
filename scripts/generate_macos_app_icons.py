#!/usr/bin/env python3
"""Build the macOS icon set from the committed branded iOS icon (Pillow)."""
import json
from pathlib import Path

from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent.parent
source = root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png'
target = root / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
catalog = json.loads((target / 'Contents.json').read_text())
with Image.open(source) as image:
    tile = image.convert('RGBA').resize((824, 824), Image.Resampling.LANCZOS)
mask = Image.new('L', tile.size)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 823, 823), radius=180, fill=255)
tile.putalpha(mask)
canvas = Image.new('RGBA', (1024, 1024))
canvas.paste(tile, (100, 100))
for name in {entry['filename'] for entry in catalog['images']}:
    size = int(name.rsplit('_', 1)[1].split('.')[0])
    canvas.resize((size, size), Image.Resampling.LANCZOS).save(target / name)
