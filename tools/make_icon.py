"""生成 App 图标：白底 + 蓝色 WiFi 符号（1024×1024）"""

import math
import os

from PIL import Image, ImageDraw

SIZE = 1024
SS = 4                      # 超采样倍数
W = SIZE * SS

BLUE = (26, 115, 232, 255)  # #1A73E8
WHITE = (255, 255, 255, 255)

img = Image.new("RGBA", (W, W), WHITE)
d = ImageDraw.Draw(img)

cx, cy = W // 2, int(W * 0.735)      # 圆心（Wi‑Fi 的圆点位置）
dot_r = int(W * 0.053)
stroke = int(W * 0.075)
radii = [int(W * 0.190), int(W * 0.330), int(W * 0.470)]

# 圆点
d.ellipse([cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r], fill=BLUE)

# 三道弧：以圆点为中心，向上张开 90°
start_angle, end_angle = 232, 308
for r in radii:
    box = [cx - r, cy - r, cx + r, cy + r]
    d.arc(box, start=start_angle, end=end_angle, fill=BLUE, width=stroke)
    # 端点补圆，做出圆头效果。
    # 注意：Pillow 的 arc(width=) 把线宽画在包围盒**内侧**，
    # 所以描边中心线在 r - stroke/2 处，圆头必须放在这里，否则会向外凸出一块。
    for ang in (start_angle, end_angle):
        rad = math.radians(ang)
        rc = r - stroke / 2
        px = cx + rc * math.cos(rad)
        py = cy + rc * math.sin(rad)
        half = stroke / 2
        d.ellipse([px - half, py - half, px + half, py + half], fill=BLUE)

icon = img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")

out_dir = os.path.join(
    r"E:\MCDOWNLOAD\others\personal files\others\网络\campus-net-ios",
    "CampusNet", "Assets.xcassets", "AppIcon.appiconset",
)
os.makedirs(out_dir, exist_ok=True)
out_path = os.path.join(out_dir, "AppIcon.png")
icon.save(out_path, "PNG")

preview = os.path.join(
    r"E:\MCDOWNLOAD\others\personal files\others\网络\campus-net-ios",
    "dist", "icon-preview.png",
)
os.makedirs(os.path.dirname(preview), exist_ok=True)
icon.save(preview, "PNG")

print("saved:", out_path)
print("size :", icon.size, "mode:", icon.mode)
print("preview:", preview)
