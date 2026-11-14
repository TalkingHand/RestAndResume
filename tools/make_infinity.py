# Writes the fitness window's "no limit" sign: a white infinity sign on transparent, antialiased
# (4x4 supersampling of a stroked curve), no blur. Pure Python (no PIL).
# python tools/make_infinity.py  ->  Contents/mods/RestAndResume/42/media/textures/RestAndResume_Infinity.png
import math, struct, zlib, os
W, H = 56, 30          # ink 52x28; drawn at 40% of a ~25 px time box (~10 px ink), so about 3x
STROKE = 4.0           # px at this size -> about 1.5 px drawn at 40% of the box
A = 24.0               # half width of the curve; ink box about 52 x 28
YS = 1.4               # taller than a Bernoulli lemniscate (2.8:1) -> about 2:1 like font glyphs
SS = 4                 # supersamples per axis
cx, cy = W / 2.0, H / 2.0
pts = []
N = 2000
for i in range(N):
    t = 2 * math.pi * i / N
    d = 1 + math.sin(t) ** 2
    pts.append((cx + A * math.cos(t) / d, cy + YS * A * math.sin(t) * math.cos(t) / d))
segs = [(pts[i], pts[(i + 1) % N]) for i in range(N)]
half = STROKE / 2.0
def dist2(px, py, a, b):
    ax, ay = a; bx, by = b
    dx, dy = bx - ax, by - ay
    l = dx * dx + dy * dy
    u = 0.0 if l == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l))
    qx, qy = ax + u * dx - px, ay + u * dy - py
    return qx * qx + qy * qy
rows = []
for y in range(H):
    row = bytearray([0])
    near = [s for s in segs if min(s[0][1], s[1][1]) - half - 1 <= y + 1 and max(s[0][1], s[1][1]) + half + 1 >= y]
    for x in range(W):
        cand = [s for s in near if min(s[0][0], s[1][0]) - half - 1 <= x + 1 and max(s[0][0], s[1][0]) + half + 1 >= x]
        hit = 0
        if cand:
            for sy in range(SS):
                for sx in range(SS):
                    px, py = x + (sx + 0.5) / SS, y + (sy + 0.5) / SS
                    if any(dist2(px, py, a, b) <= half * half for a, b in cand):
                        hit += 1
        row += bytes([255, 255, 255, round(255 * hit / (SS * SS))])
    rows.append(bytes(row))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0)) \
    + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
out = os.path.join(os.path.dirname(__file__), '..', 'Contents', 'mods', 'RestAndResume', '42', 'media', 'textures', 'RestAndResume_Infinity.png')
open(out, 'wb').write(png)
print(out, W, H)
