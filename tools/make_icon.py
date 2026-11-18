#!/usr/bin/env python3
"""纯标准库生成 App 图标 PNG（无 Pillow 依赖）。

设计：深空背景 + 青绿同心波纹 + 中心亮点（暗示「实况/播放」）。
用距离场做解析抗锯齿，1024 尺寸几秒内出图。
"""
import math
import struct
import sys
import zlib


def clamp01(v):
    return 0.0 if v < 0 else (1.0 if v > 1 else v)


def round_rect_cov(x, y, cx, cy, hw, hh, r, aa):
    """圆角矩形的覆盖率（距离场解析抗锯齿）。"""
    dx = abs(x - cx) - (hw - r)
    dy = abs(y - cy) - (hh - r)
    if dx <= 0 and dy <= 0:
        d = max(dx, dy) - r
    else:
        ox = dx if dx > 0 else 0.0
        oy = dy if dy > 0 else 0.0
        d = math.hypot(ox, oy) + min(max(dx, dy), 0.0) - r
    return clamp01(0.5 - d / aa)


def ring_cov(x, y, cx, cy, radius, width, aa):
    d = math.hypot(x - cx, y - cy)
    return clamp01(0.5 - (abs(d - radius) - width * 0.5) / aa)


def disc_cov(x, y, cx, cy, radius, aa):
    d = math.hypot(x - cx, y - cy)
    return clamp01(0.5 - (d - radius) / aa)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def render(size):
    S = float(size)
    cx = cy = S * 0.5

    bg_top = (0.105, 0.125, 0.185)
    bg_bot = (0.020, 0.028, 0.045)
    accent = (0.290, 0.870, 0.720)
    white = (1.0, 1.0, 1.0)

    corner = S * 0.2237          # iOS squircle 近似半径
    aa = 1.4

    out = bytearray(size * size * 4)

    r_outer = S * 0.300
    w_outer = S * 0.058
    r_mid = S * 0.176
    w_mid = S * 0.042
    r_dot = S * 0.070

    for y in range(size):
        fy = y + 0.5
        grad = clamp01(fy / S)
        base = mix(bg_top, bg_bot, grad)
        row = y * size * 4
        for x in range(size):
            fx = x + 0.5

            shape = round_rect_cov(fx, fy, cx, cy, S * 0.5, S * 0.5, corner, aa)
            if shape <= 0.0:
                continue

            # 背景（在圆角内）
            r, g, b = base

            # 顶部一层极淡的青光，让图标有体积感
            glow = clamp01(1.0 - math.hypot(fx - cx, fy - S * 0.18) / (S * 0.72))
            glow = glow * glow * 0.16
            r += (accent[0] - r) * glow
            g += (accent[1] - g) * glow
            b += (accent[2] - b) * glow

            # 外环
            c1 = ring_cov(fx, fy, cx, cy, r_outer, w_outer, aa)
            if c1 > 0:
                r += (accent[0] - r) * c1
                g += (accent[1] - g) * c1
                b += (accent[2] - b) * c1

            # 中环（半透明）
            c2 = ring_cov(fx, fy, cx, cy, r_mid, w_mid, aa) * 0.55
            if c2 > 0:
                r += (accent[0] - r) * c2
                g += (accent[1] - g) * c2
                b += (accent[2] - b) * c2

            # 中心亮点
            c3 = disc_cov(fx, fy, cx, cy, r_dot, aa)
            if c3 > 0:
                r += (white[0] - r) * c3
                g += (white[1] - g) * c3
                b += (white[2] - b) * c3

            o = row + x * 4
            out[o] = int(clamp01(r) * 255)
            out[o + 1] = int(clamp01(g) * 255)
            out[o + 2] = int(clamp01(b) * 255)
            out[o + 3] = int(shape * 255)
    return bytes(out)


def write_png(path, w, h, rgba):
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "AppIcon1024.png"
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
    rgba = render(size)
    write_png(path, size, size, rgba)
    print(f"icon written: {path} ({size}x{size})")


if __name__ == "__main__":
    main()
