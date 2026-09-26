#!/usr/bin/env python3
"""Render the app icon: the avatar tlx draws for the word "hello", in its light tones."""

import hashlib

from PIL import Image, ImageColor, ImageDraw

SIZE = 1024

digest = hashlib.sha256(b"hello").digest()
hue = digest[0] % 12 * 30
cells = [(digest[1 + index // 8] >> (index % 8)) & 1 == 1 for index in range(15)]
next_byte = 3
while sum(cells) < 6:
    cells[digest[next_byte] % 15] = True
    next_byte += 1
while sum(cells) > 11:
    cells[digest[next_byte] % 15] = False
    next_byte += 1

image = Image.new("RGB", (SIZE, SIZE), ImageColor.getrgb(f"hsv({hue},25%,97%)"))
draw = ImageDraw.Draw(image)
unit = SIZE // 8
for row in range(5):
    for column in range(5):
        if cells[row * 3 + (column if column < 3 else 4 - column)]:
            x, y = (3 + 2 * column) * unit // 2, (3 + 2 * row) * unit // 2
            draw.rectangle([x, y, x + unit - 1, y + unit - 1], fill=ImageColor.getrgb(f"hsv({hue},60%,50%)"))
image.save("Assets.xcassets/AppIcon.appiconset/icon.png")
