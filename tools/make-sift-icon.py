"""用 design/sift-icon-source.webp 生成 App 图标：python3 tools/make-sift-icon.py
白色圆角方块 + 居中的插画，按 macOS 图标规范留出四周边距，输出 AppIcon.appiconset 的各个尺寸。"""
from PIL import Image, ImageDraw, ImageFilter
import os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
art = Image.open(os.path.join(root, "design/sift-icon-source.webp")).convert("RGBA")
out_dir = os.path.join(root, "App/Assets.xcassets/AppIcon.appiconset")
S = 2048  # 2x 超采样，缩小后边缘更平滑
tile, radius = int(S * 824 / 1024), int(S * 185 / 1024)
off = (S - tile) // 2

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((off, off + 14, off + tile, off + tile + 14), radius, fill=(40, 50, 110, 70))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle((off, off, off + tile, off + tile), radius, fill=255)
body = Image.new("RGBA", (S, S), (255, 255, 255, 255))
side = int(tile * 1.0)
scaled = art.resize((side, side), Image.LANCZOS)
body.alpha_composite(scaled, ((S - side) // 2, (S - side) // 2))
canvas.paste(body, (0, 0), mask)

names = {"icon_16x16@1x": 16, "icon_16x16@2x": 32, "icon_32x32@1x": 32, "icon_32x32@2x": 64,
         "icon_128x128@1x": 128, "icon_128x128@2x": 256, "icon_256x256@1x": 256, "icon_256x256@2x": 512,
         "icon_512x512@1x": 512, "icon_512x512@2x": 1024}
for name, px in names.items():
    canvas.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name + ".png"))
