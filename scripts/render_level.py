#!/usr/bin/env python3
"""Рисует уровень и решение по петлям (вид сверху) из build/level.json → docs/img/level.png. Нужен Pillow.

Каждый «я» — свой цвет петли: путь, номер у старта и в конце (где он остался стоять),
квадрат — держит переключатель (до скольких секунд), 🔑 — взял ключ. Справа — легенда ролей."""
import json, sys
from PIL import Image, ImageDraw, ImageFont

src = sys.argv[1] if len(sys.argv) > 1 else "build/level.json"
dst = sys.argv[2] if len(sys.argv) > 2 else "build/level.png"
d = json.load(open(src))

S = 40  # px на клетку
PAD = 24
SIDE = 430
W, H = d["w"] * S + PAD * 2, d["h"] * S + PAD * 2
img = Image.new("RGB", (W + SIDE, max(H, 520)), (16, 18, 34))
dr = ImageDraw.Draw(img, "RGBA")
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONTB = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
f12, f15, f18, f22 = (ImageFont.truetype(FONT, 12), ImageFont.truetype(FONT, 15),
                      ImageFont.truetype(FONTB, 18), ImageFont.truetype(FONTB, 22))


def P(x, y):
    return PAD + x * S, PAD + y * S


def rgb(c, a=255):
    return (c[0], c[1], c[2], a)


door_at = {(q["x"], q["y"]): q for q in d["doors"]}
# пол и стены
for y, row in enumerate(d["cells"]):
    for x, c in enumerate(row):
        x0, y0 = P(x, y)
        if c == 0:
            dr.rectangle([x0, y0, x0 + S, y0 + S], fill=(22, 23, 40))
        else:
            dark = (x + y) % 2 == 0
            dr.rectangle([x0, y0, x0 + S - 1, y0 + S - 1], fill=(70, 76, 120) if dark else (80, 86, 132))
tr = d["treasure"]
# зона хранилища — золотистая (клетки вокруг сокровища до стен)
seen, stack = set(), [(tr["x"], tr["y"])]
while stack:
    x, y = stack.pop()
    if (x, y) in seen or (x, y) in door_at or d["cells"][y][x] == 0:
        continue
    seen.add((x, y))
    x0, y0 = P(x, y)
    dr.rectangle([x0, y0, x0 + S - 1, y0 + S - 1], fill=(96, 78, 42))
    stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]

sw = d["switchColors"]
gold = (255, 200, 60)
for q in d["doors"]:
    x0, y0 = P(q["x"], q["y"])
    if q["kind"] == "switch":
        c = sw[(q["color"] - 1) % len(sw)]["rgb"]
        g = sw[(q["color"] - 1) % len(sw)]["glyph"]
    elif q["kind"] == "lock":
        c, g = (230, 130, 50), "L"
    else:
        c, g = gold, "V"
    dr.rectangle([x0 + 4, y0 + 4, x0 + S - 4, y0 + S - 4], fill=rgb(c, 200), outline=(255, 255, 255))
    dr.text((x0 + S / 2, y0 + S / 2), g, font=f15, fill=(20, 20, 30), anchor="mm")
for p in d["plates"]:
    x0, y0 = P(p["x"], p["y"])
    if p["kind"] == "vault":
        c, g = gold, "★"
    else:
        c = sw[(p["color"] - 1) % len(sw)]["rgb"]
        g = sw[(p["color"] - 1) % len(sw)]["glyph"]
    dr.ellipse([x0 + 7, y0 + 7, x0 + S - 7, y0 + S - 7], fill=rgb(c), outline=(20, 20, 30), width=2)
    dr.text((x0 + S / 2, y0 + S / 2), g, font=f15, fill=(20, 20, 30), anchor="mm")
for k in d["keys"]:
    x0, y0 = P(k["x"], k["y"])
    dr.ellipse([x0 + 12, y0 + 10, x0 + 24, y0 + 22], outline=(255, 235, 150), width=3)
    dr.line([x0 + 22, y0 + 18, x0 + 32, y0 + 28], fill=(255, 235, 150), width=3)
x0, y0 = P(tr["x"], tr["y"])
dr.polygon([(x0 + S / 2, y0 + 5), (x0 + S - 6, y0 + S / 2), (x0 + S / 2, y0 + S - 5), (x0 + 6, y0 + S / 2)],
           fill=(120, 255, 230), outline=(255, 255, 255))
st = d["start"]
x0, y0 = P(st["x"], st["y"])
dr.ellipse([x0 + 3, y0 + 3, x0 + S - 3, y0 + S - 3], outline=(150, 130, 255), width=3)

# пути «я»
LC = d["loopColors"]
n = len(d["selves"])
for i, s in enumerate(d["selves"]):
    c = LC[i % len(LC)]
    off = (i - (n - 1) / 2) * 3
    pts = [(PAD + x * S + off, PAD + y * S + off) for x, y in s["points"]]
    if len(pts) > 1:
        dr.line(pts, fill=rgb(c, 230), width=4, joint="curve")
    ex, ey = pts[-1]
    dr.ellipse([ex - 11, ey - 11, ex + 11, ey + 11], fill=rgb(c), outline=(255, 255, 255), width=2)
    dr.text((ex, ey), str(i + 1), font=f15, fill=(15, 15, 25), anchor="mm")
    for t in s["tasks"]:
        if t["kind"] == "hold":
            hx, hy = P(t["x"] + 0.5, t["y"] + 0.5)
            dr.rectangle([hx - 14 + off, hy - 14 + off, hx + 14 + off, hy + 14 + off], outline=rgb(c), width=3)

# легенда
lx = W + 10
dr.text((lx, 22), f"Уровень {d['n']} · нужно {d['k']} «тебя»", font=f22, fill=(240, 240, 255))
dr.text((lx, 54), f"решатель: хранилище вскрыто на {d['win']:.1f} с из 15", font=f15, fill=(170, 180, 210))
m = d["metrics"]
dr.text((lx, 76), f"передач {m['relays']} · ключей {m['keys']} · ожидание ≤ {m['idleMax']:.1f} с · D = {m['D']}",
        font=f15, fill=(170, 180, 210))
y = 116
for i, s in enumerate(d["selves"]):
    c = LC[i % len(LC)]
    dr.ellipse([lx, y, lx + 22, y + 22], fill=rgb(c))
    dr.text((lx + 11, y + 11), str(i + 1), font=f15, fill=(15, 15, 25), anchor="mm")
    parts = []
    for t in s["tasks"]:
        if t["kind"] == "hold":
            g = sw[(t["color"] - 1) % len(sw)]["glyph"]
            parts.append(f"держит {g} до {t.get('until', 0):.1f} с")
        elif t["kind"] == "key":
            parts.append("ключ")
        elif t["kind"] == "unlock":
            parts.append("замок")
        elif t["kind"] == "plate":
            parts.append(f"★ плита (⟲ на {s['ends']:.1f} с)")
        elif t["kind"] == "treasure":
            parts.append("в хранилище")
    text = f"Петля {i + 1}: " + " → ".join(parts)
    # перенос по ширине
    words, line, lines = text.split(" "), "", []
    for w_ in words:
        if dr.textlength(line + " " + w_, font=f15) > SIDE - 50:
            lines.append(line)
            line = w_
        else:
            line = (line + " " + w_).strip()
    lines.append(line)
    for j, l in enumerate(lines):
        dr.text((lx + 30, y + 2 + j * 19), l, font=f15, fill=(235, 235, 245))
    y += 22 + 19 * len(lines)
y += 10
legend = [("★", "золотая плита: хранилище V открыто, пока нажаты ВСЕ"),
          ("◆●▲", "цветная плита открывает дверь своего цвета"),
          ("L", "замок: открывается ключом до конца петли"),
          ("□", "квадрат — держит переключатель для будущего себя")]
for g, t in legend:
    dr.text((lx, y), g, font=f15, fill=gold)
    dr.text((lx + 52, y), t, font=f12, fill=(170, 180, 210))
    y += 20
img.save(dst)
print("saved", dst)
