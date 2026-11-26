#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 LiveFace 应用图标（1024px PNG + .icns）。

设计：深色玻璃拟态底 + 两张叠放的圆形头像（一张渐变实心、一张玻璃描边），
右下角白色徽章内的双向箭头表示“换脸”。所有绘制在 3× 超采样画布上完成，
再缩到 1024，边缘干净。
"""
from __future__ import annotations

import math
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent
S = 3
N = 1024 * S


def sc(*vals: float) -> list[float]:
    return [v * S for v in vals]


def rounded_mask(box, radius: float) -> Image.Image:
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def circle_mask(cx: float, cy: float, r: float) -> Image.Image:
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).ellipse(sc(cx - r, cy - r, cx + r, cy + r), fill=255)
    return m


def gradient(c1, c2, angle: float = 45.0) -> Image.Image:
    yy, xx = np.mgrid[0:N, 0:N]
    rad = math.radians(angle)
    proj = xx * math.cos(rad) + yy * math.sin(rad)
    t = (proj - proj.min()) / (proj.max() - proj.min())
    a = np.array(c1, dtype=np.float32)
    b = np.array(c2, dtype=np.float32)
    arr = (a * (1 - t)[..., None] + b * t[..., None]).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def blur_layer(layer: Image.Image, radius: float) -> Image.Image:
    return layer.filter(ImageFilter.GaussianBlur(radius * S))


def clip_alpha(layer: Image.Image, mask: Image.Image) -> Image.Image:
    layer.putalpha(ImageChops.multiply(layer.getchannel("A"), mask))
    return layer


def draw_person(cx: float, cy: float, r: float, scale: float, color) -> Image.Image:
    """头像里的半身剪影（头 + 肩），裁剪到圆形头像内。"""
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    head_r = 49 * scale
    head_cy = cy - 54 * scale
    d.ellipse(
        sc(cx - head_r, head_cy - head_r, cx + head_r, head_cy + head_r),
        fill=color,
    )
    # 肩部用椭圆，被头像圆裁掉下半部分，形成自然的半身曲线
    d.ellipse(
        sc(cx - 97 * scale, cy + 26 * scale,
           cx + 97 * scale, cy + 250 * scale),
        fill=color,
    )
    return clip_alpha(layer, circle_mask(cx, cy, r))


def shadow_of(mask: Image.Image, blur: float, alpha: int, dy: float) -> Image.Image:
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    black = Image.new("RGBA", (N, N), (0, 0, 0, alpha))
    layer.paste(black, (0, int(dy * S)), mask)
    return blur_layer(layer, blur)


def main() -> None:
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # ---- 外阴影 ----
    icon_box = sc(100, 100, 924, 924)
    icon_radius = 185 * S
    icon_mask = rounded_mask(icon_box, icon_radius)
    canvas = Image.alpha_composite(
        canvas, shadow_of(icon_mask, blur=26, alpha=120, dy=18)
    )

    # ---- 底：深色渐变 ----
    base = gradient((28, 45, 96, 255), (7, 10, 20, 255), 48)
    canvas.paste(base, (0, 0), icon_mask)

    # ---- 极光色斑 ----
    aurora = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ad = ImageDraw.Draw(aurora)
    ad.ellipse(sc(40, -150, 690, 400), fill=(91, 140, 255, 165))
    ad.ellipse(sc(560, -180, 1120, 300), fill=(34, 211, 238, 95))
    ad.ellipse(sc(-120, 620, 470, 1140), fill=(124, 58, 237, 80))
    aurora = blur_layer(aurora, 100)
    aurora.putalpha(ImageChops.multiply(aurora.getchannel("A"), icon_mask))
    canvas = Image.alpha_composite(canvas, aurora)

    # ---- 左上玻璃高光 ----
    gloss = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gd.ellipse(sc(80, 70, 620, 300), fill=(255, 255, 255, 26))
    gloss = blur_layer(gloss, 46)
    gloss.putalpha(ImageChops.multiply(gloss.getchannel("A"), icon_mask))
    canvas = Image.alpha_composite(canvas, gloss)

    # ---- 后方头像（玻璃） ----
    bx, by, br = 668, 372, 160
    bmask = circle_mask(bx, by, br)
    canvas = Image.alpha_composite(
        canvas, shadow_of(bmask, blur=18, alpha=85, dy=14)
    )
    back = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    bd = ImageDraw.Draw(back)
    bd.ellipse(sc(bx - br, by - br, bx + br, by + br), fill=(255, 255, 255, 30))
    bd.ellipse(
        sc(bx - br, by - br, bx + br, by + br),
        outline=(255, 255, 255, 120), width=int(2.4 * S),
    )
    back.putalpha(ImageChops.multiply(back.getchannel("A"), bmask))
    canvas = Image.alpha_composite(canvas, back)
    canvas = Image.alpha_composite(
        canvas, draw_person(bx, by, br, br / 160, (255, 255, 255, 105))
    )

    # ---- 前方头像（渐变实心） ----
    fx, fy, fr = 418, 556, 186
    fmask = circle_mask(fx, fy, fr)

    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    glow.paste(Image.new("RGBA", (N, N), (74, 123, 240, 130)), (0, 0), fmask)
    glow = blur_layer(glow, 34)
    canvas = Image.alpha_composite(canvas, glow)
    canvas = Image.alpha_composite(
        canvas, shadow_of(fmask, blur=14, alpha=95, dy=12)
    )

    front = gradient((111, 155, 255, 255), (34, 211, 238, 255), 55)
    front.putalpha(ImageChops.multiply(front.getchannel("A"), fmask))
    canvas = Image.alpha_composite(canvas, front)

    # 头像内部上缘高光
    inner = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    idr = ImageDraw.Draw(inner)
    idr.ellipse(sc(fx - fr + 18, fy - fr + 8, fx + fr - 18, fy - 10),
                fill=(255, 255, 255, 60))
    inner = blur_layer(inner, 26)
    inner.putalpha(ImageChops.multiply(
        ImageChops.multiply(inner.getchannel("A"), fmask), fmask))
    canvas = Image.alpha_composite(canvas, inner)

    # 底部暗部，增加球体体积感
    shade = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shade).ellipse(
        sc(fx - fr, fy + 10, fx + fr, fy + fr + 30),
        fill=(3, 8, 20, 80),
    )
    shade = blur_layer(shade, 30)
    shade.putalpha(ImageChops.multiply(shade.getchannel("A"), fmask))
    canvas = Image.alpha_composite(canvas, shade)

    canvas = Image.alpha_composite(
        canvas, draw_person(fx, fy, fr, fr / 186, (7, 16, 34, 235))
    )

    # ---- 右下徽章 + 双向箭头 ----
    ccx, ccy, cr = 650, 692, 92
    cmask = circle_mask(ccx, ccy, cr)
    canvas = Image.alpha_composite(
        canvas, shadow_of(cmask, blur=12, alpha=110, dy=10)
    )
    badge = gradient((255, 255, 255, 255), (219, 232, 255, 255), 35)
    badge.putalpha(ImageChops.multiply(badge.getchannel("A"), cmask))
    canvas = Image.alpha_composite(canvas, badge)
    ring = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse(
        sc(ccx - cr, ccy - cr, ccx + cr, ccy + cr),
        outline=(255, 255, 255, 210), width=int(1.6 * S),
    )
    canvas = Image.alpha_composite(canvas, ring)

    arrow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    adr = ImageDraw.Draw(arrow)
    ink = (10, 20, 40, 255)
    w = int(13 * S)
    # 上箭头 → 右
    y1 = ccy - 23
    adr.line(sc(ccx - 44, y1, ccx + 38, y1), fill=ink, width=w)
    adr.polygon(
        [(ccx + 33) * S, (y1 - 20) * S,
         (ccx + 33) * S, (y1 + 20) * S,
         (ccx + 60) * S, y1 * S],
        fill=ink,
    )
    # 下箭头 → 左
    y2 = ccy + 23
    adr.line(sc(ccx + 44, y2, ccx - 38, y2), fill=ink, width=w)
    adr.polygon(
        [(ccx - 33) * S, (y2 - 20) * S,
         (ccx - 33) * S, (y2 + 20) * S,
         (ccx - 60) * S, y2 * S],
        fill=ink,
    )
    # 圆头
    for x, y in ((ccx - 44, y1), (ccx + 44, y2)):
        adr.ellipse(sc(x - 6.5, y - 6.5, x + 6.5, y + 6.5), fill=ink)
    canvas = Image.alpha_composite(canvas, arrow)

    # ---- 外框内描边 ----
    border = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        icon_box, radius=icon_radius,
        outline=(255, 255, 255, 46), width=int(1.6 * S),
    )
    canvas = Image.alpha_composite(canvas, border)

    # ---- 细颗粒 ----
    rng = np.random.default_rng(11)
    grain = Image.fromarray(
        (rng.normal(0, 5, (N, N)) + 128).clip(0, 255).astype(np.uint8), "L"
    ).convert("RGBA")
    grain.putalpha(10)
    grain.putalpha(ImageChops.multiply(grain.getchannel("A"), icon_mask))
    canvas = Image.alpha_composite(canvas, grain)

    # ---- 输出 ----
    icon = canvas.resize((1024, 1024), Image.LANCZOS)
    icon.save(ROOT / "AppIcon.png")

    # 预览图（深/浅背景）
    for name, bg in (("preview_dark.png", (8, 11, 18, 255)),
                     ("preview_light.png", (244, 246, 250, 255))):
        prev = Image.new("RGBA", (1024, 1024), bg)
        prev.alpha_composite(icon)
        prev.convert("RGB").save(ROOT / name)

    # 小尺寸预览条
    sheet = Image.new("RGBA", (900, 300), (8, 11, 18, 255))
    x = 42
    for s in (256, 128, 64, 32):
        im = icon.resize((s, s), Image.LANCZOS)
        sheet.alpha_composite(im, (x, (300 - s) // 2))
        x += s + 42
    sheet.convert("RGB").save(ROOT / "preview_sizes.png")

    # ---- iconset ----
    iconset = ROOT / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for logical in (16, 32, 128, 256, 512):
        for suffix, size in (("", logical), ("@2x", logical * 2)):
            img = icon.resize((size, size), Image.LANCZOS)
            img.save(iconset / f"icon_{logical}x{logical}{suffix}.png")

    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "AppIcon.icns")],
        check=True,
    )
    print("wrote", ROOT / "AppIcon.png", ROOT / "AppIcon.icns")


if __name__ == "__main__":
    main()
