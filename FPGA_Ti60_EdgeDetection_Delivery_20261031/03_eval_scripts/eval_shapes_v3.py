# -*- coding: utf-8 -*-
"""
评测 v3 —— 用"亮区包住暗目标"替代网格选格：
  1) 边框带判极性（pol=1 表示目标是暗的：纸亮、形状暗）
  2) pol=1 时：窗口 = 上一帧的【亮区 bbox】扩大 10%  → 只在纸内统计暗像素
  3) pol=0 时：窗口 = 全画面
用法: python eval_shapes_v3.py [目录]
"""
import os, sys, glob, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
FONT = "C:/Windows/Fonts/msyh.ttc"
P = dict(THRESH=128, BBX_MAX=1800, BBY_MAX=1000, A_MIN=150, A_MAX=65530,
         FILL_MIN=297, K_CIRC=10616, K_RECT=125112, CELL_MIN=150)


def load_gray(path):
    im = Image.open(path).convert("L")
    w, h = im.size
    sc = min(W / w, H / h)
    nw, nh = max(1, int(round(w * sc))), max(1, int(round(h * sc)))
    im2 = im.resize((nw, nh), Image.LANCZOS)
    a = np.array(im2)
    edge = np.concatenate([a[0, :], a[-1, :], a[:, 0], a[:, -1]])
    canvas = np.full((H, W), int(np.median(edge)), dtype=np.uint8)
    ox, oy = (W - nw) // 2, (H - nh) // 2
    canvas[oy:oy + nh, ox:ox + nw] = a
    return canvas


def bbox_of(mask):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    return int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())


def grow(bb, frac=0.10):
    x0, x1, y0, y1 = bb
    dx = max(4, int((x1 - x0) * frac)); dy = max(4, int((y1 - y0) * frac))
    return max(0, x0 - dx), min(W - 1, x1 + dx), max(0, y0 - dy), min(H - 1, y1 + dy)


def run(path, iters=2, verbose=True):
    g = load_gray(path)
    gg = g.astype(np.int64)
    ys, xs = np.mgrid[0:H, 0:W]
    smp = (ys % 4 == 0) & (xs % 4 == 0)
    band = (xs < 96) | (xs >= W - 96) | (ys < 64) | (ys >= H - 64)
    n_hi = int(((gg > P["THRESH"]) & smp & band).sum())
    n_lo = int(((gg <= P["THRESH"]) & smp & band).sum())
    pol = 0 if n_hi <= n_lo else 1

    bright = (gg > P["THRESH"])
    dark = (gg <= P["THRESH"])
    fg = dark if pol else bright

    win = None
    bb_bright = None
    for it in range(iters):
        bb_bright = bbox_of(bright & smp)                     # 上一帧亮区 bbox
        win = grow(bb_bright) if (pol and bb_bright) else (0, W - 1, 0, H - 1)

    x0, x1, y0, y1 = win
    m = fg & smp & (xs >= x0) & (xs <= x1) & (ys >= y0) & (ys <= y1)
    a = int(m.sum())
    rej = []
    if a < P["A_MIN"]:
        rej.append(f"面积{a}")
    bb = bbox_of(m)
    fill = cg = 0.0
    bw = bh = 0
    if bb:
        bx0, bx1, by0, by1 = bb
        bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
        if bx0 == 0 or by0 == 0 or bx1 >= W - 1 or by1 >= H - 1:
            rej.append("触边")
        if bw > P["BBX_MAX"] or bh > P["BBY_MAX"]:
            rej.append(f"bbox{bw}x{bh}")
        fill = 16 * a / (bw * bh)
        if 16 * a * 1024 < P["FILL_MIN"] * bw * bh:
            rej.append(f"fill{fill:.2f}")
        if not (bw * 4 >= bh and bh * 4 >= bw):
            rej.append(f"aspect{bw}/{bh}")
    cls = 0
    if not rej and a:
        y = ys[m].astype(np.int64); x = xs[m].astype(np.int64)
        sx, sy = int(x.sum()), int(y.sum())
        sxx, syy, sxy = int((x * x).sum()), int((y * y).sum()), int((x * y).sum())
        a2 = a * a
        m20 = ((a * sxx - sx * sx) << 12) // a2
        m02 = ((a * syy - sy * sy) << 12) // a2
        m11 = (abs(a * sxy - sx * sy) << 12) // a2
        circ = (a * P["K_CIRC"] >= m20 + m02)
        lq = max((m20 >> 4) * (m02 >> 4) - (m11 >> 4) ** 2, 0)
        rect = (lq <= P["K_RECT"] * a2)
        cg = 16 * a / (math.pi * ((m20 + m02) / 4096)) if (m20 + m02) else 0
        cls = 1 if circ else (2 if rect else 0)
        if cls == 0:
            rej.append("判据不符")
    if verbose:
        print(f"{os.path.basename(path)[:34]:34s} pol={pol} 亮区={bb_bright} "
              f"A={a:6d} bbox={f'{bw}x{bh}':>9s} fill={fill:4.2f} cg={cg:4.2f} "
              f"→ {['未知','圆  ','矩形'][cls]} {','.join(rej)}")
    return dict(pol=pol, a=a, bb=bb, bb_bright=bb_bright, win=win, fill=fill, cg=cg,
                cls=cls, why=",".join(rej), file=os.path.basename(path))


def annotate(path, r, outdir):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    sc = min(W / w, H / h)
    nw, nh = int(round(w * sc)), int(round(h * sc))
    im = im.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGB", (W, H), (40, 40, 40))
    canvas.paste(im, ((W - nw) // 2, (H - nh) // 2))
    d = ImageDraw.Draw(canvas)
    try:
        f = ImageFont.truetype(FONT, 32)
    except Exception:
        f = ImageFont.load_default()
    if r["win"]:
        x0, x1, y0, y1 = r["win"]
        d.rectangle([x0 // 2, y0, x1 // 2, y1], outline=(255, 200, 0), width=2)
    if r["bb"]:
        bx0, bx1, by0, by1 = r["bb"]
        col = (0, 220, 0) if r["cls"] else (255, 70, 70)
        d.rectangle([bx0 // 2, by0, bx1 // 2, by1], outline=col, width=4)
    col = (0, 220, 0) if r["cls"] else (255, 70, 70)
    d.text((16, H - 44), f"{['未知','圆','矩形'][r['cls']]} A={r['a']} fill={r['fill']:.2f} "
                         f"cg={r['cg']:.2f} {r['why']}", fill=col, font=f)
    out = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0] + ".png")
    canvas.save(out)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "数据集"
    files = []
    for e in ("*.jpg", "*.jpeg", "*.png", "*.bmp", "*.JPG"):
        files += glob.glob(os.path.join(root, e))
    files = sorted(set(files))
    outdir = os.path.join(root, "eval_out_v3")
    os.makedirs(outdir, exist_ok=True)
    print("=" * 130)
    print(f"{'文件':34s} {'pol':>3s} {'亮区bbox':>22s} {'A':>7s} {'bbox':>10s} {'fill':>5s} {'cg':>5s}  判定 原因")
    print("=" * 130)
    rows = []
    for p in files:
        r = run(p)
        annotate(p, r, outdir)
        rows.append(r)
    print("-" * 130)
    from collections import Counter
    c = Counter(r["cls"] for r in rows)
    print(f"共 {len(rows)} 张 ｜ 圆 {c[1]} ｜ 矩形 {c[2]} ｜ 未知 {c[0]}")
    print(f"标注图 → {outdir}")


if __name__ == "__main__":
    main()
