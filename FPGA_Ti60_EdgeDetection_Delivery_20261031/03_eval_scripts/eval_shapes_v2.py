# -*- coding: utf-8 -*-
"""
数据集评测 v2 —— 与 RTL R10 等价（边框带极性 + 4×4 网格 + 窗口门控 + 填充度/宽高比/格计数）
用法: python eval_shapes_v2.py [目录] [--iters 3]
输出: 控制台表 + eval_v2.csv + 标注图到 <目录>/eval_out_v2/
说明: 图像等比缩放到 1920×1080（补边，不拉伸），模拟相机整幅视场。
"""
import os, sys, glob, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
FONT = "C:/Windows/Fonts/msyh.ttc"
P = dict(THRESH=128, TH_MODE=0, TH_DELTA=24, BBX_MAX=1800, BBY_MAX=1000,
         A_MIN=150, A_MAX=65530, FILL_MIN=297, K_CIRC=10616, K_RECT=125112,
         CELL_MIN=150)


def load_gray(path):
    im = Image.open(path).convert("L")
    w, h = im.size
    # 等比缩放到 1920x1080 内，再补边（补边色 = 图像边缘中值）
    sc = min(W / w, H / h)
    nw, nh = max(1, int(round(w * sc))), max(1, int(round(h * sc)))
    im2 = im.resize((nw, nh), Image.LANCZOS)
    a = np.array(im2)
    edge = np.concatenate([a[0, :], a[-1, :], a[:, 0], a[:, -1]])
    pad = int(np.median(edge))
    canvas = np.full((H, W), pad, dtype=np.uint8)
    ox, oy = (W - nw) // 2, (H - nh) // 2
    canvas[oy:oy + nh, ox:ox + nw] = a
    return canvas, (ox, oy, nw, nh, sc, im.size)


def stats(mask, box=None):
    ys, xs = np.mgrid[0:H, 0:W]
    smp = (ys % 4 == 0) & (xs % 4 == 0)
    m = mask & smp
    if box is not None:
        x0, x1, y0, y1 = box
        m = m & (xs >= x0) & (xs <= x1) & (ys >= y0) & (ys <= y1)
    a = int(m.sum())
    if a == 0:
        return a, None
    y = ys[m].astype(np.int64); x = xs[m].astype(np.int64)
    return a, (int(x.min()), int(x.max()), int(y.min()), int(y.max()))


def classify(a, bb):
    if a == 0 or bb is None:
        return 0, f"无前景"
    bx0, bx1, by0, by1 = bb
    bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
    rej = []
    if a < P["A_MIN"]:
        rej.append(f"面积{a}")
    if bx0 == 0 or by0 == 0 or bx1 >= W - 1 or by1 >= H - 1:
        rej.append("触边")
    if bw > P["BBX_MAX"] or bh > P["BBY_MAX"]:
        rej.append(f"bbox{bw}x{bh}")
    fill = 16 * a / (bw * bh)
    if 16 * a * 1024 < P["FILL_MIN"] * bw * bh:
        rej.append(f"fill{fill:.2f}")
    if not (bw * 4 >= bh and bh * 4 >= bw):
        rej.append(f"aspect{bw}/{bh}")
    return (0 if rej else 1), (",".join(rej) if rej else ""), fill, bw, bh


def moments(mask, bb):
    ys, xs = np.mgrid[0:H, 0:W]
    smp = (ys % 4 == 0) & (xs % 4 == 0)
    m = mask & smp
    y = ys[m].astype(np.int64); x = xs[m].astype(np.int64)
    a = len(x)
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
    return circ, rect, cg


def run(path, iters=3, verbose=True):
    g, meta = load_gray(path)
    gg = g.astype(np.int64)
    ys, xs = np.mgrid[0:H, 0:W]
    smp = (ys % 4 == 0) & (xs % 4 == 0)
    band = (xs < 96) | (xs >= W - 96) | (ys < 64) | (ys >= H - 64)
    n_hi_b = int(((gg > P["THRESH"]) & smp & band).sum())
    n_lo_b = int(((gg <= P["THRESH"]) & smp & band).sum())
    pol = 0 if n_hi_b <= n_lo_b else 1          # 边框带多数是背景；另一类为目标
    fg = (gg <= P["THRESH"]) if pol else (gg > P["THRESH"])

    cell = (ys // 270) * 4 + (xs // 480)
    win = None
    best = 0
    hist = []
    for it in range(iters):
        cnt = np.bincount(cell[fg & smp].ravel(), minlength=16)
        best = int(cnt.argmax())
        bcx, bcy = best % 4, best // 4
        win = (max(0, bcx * 480 - 240), min(W - 1, bcx * 480 + 719),
               max(0, bcy * 270 - 135), min(H - 1, bcy * 270 + 404))
        hist.append((int(cnt[best]), best, win))

    aW, bbW = stats(fg, win)
    aG, bbG = stats(fg, None)
    res = classify(aW, bbW)
    cls, why, fill, bw, bh = (res + (0, 0, 0))[:5] if len(res) < 5 else (res[0], res[1], res[2], res[3], res[4])
    if cls == 1:
        circ, rect, cg = moments(fg, win)
        if circ:
            cls = 1
        elif rect:
            cls = 2
        else:
            cls = 0
            why = (why + ",判据不符").strip(",")
    else:
        cg = 0
    if hist[-1][0] < P["CELL_MIN"]:
        cls = 0
        why = (why + f",格计数{hist[-1][0]}").strip(",")
    out = dict(mu=int(gg.mean()), pol=pol, best=best, cell_cnt=hist[-1][0],
               a_win=aW, bb_win=bbW, a_glob=aG, bb_glob=bbG, fill=fill, cg=cg,
               cls=cls, why=why, win=win, meta=meta)
    if verbose:
        print(f"{os.path.basename(path)[:34]:34s} mu={out['mu']:3d} pol={pol} "
              f"格={best:2d}({out['cell_cnt']:5d}) A={aW:6d} "
              f"bbox={f'{bw}x{bh}':>9s} fill={fill:4.2f} cg={cg:4.2f} "
              f"→ {['未知','圆  ','矩形'][cls]} {why}")
    return out


def annotate(path, r, outdir):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    sc = min(W / w, H / h)
    nw, nh = int(round(w * sc)), int(round(h * sc))
    im = im.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGB", (W, H), (40, 40, 40))
    ox, oy = (W - nw) // 2, (H - nh) // 2
    canvas.paste(im, (ox, oy))
    d = ImageDraw.Draw(canvas)
    try:
        f = ImageFont.truetype(FONT, 34)
    except Exception:
        f = ImageFont.load_default()
    # 网格线（浅）
    for kx in range(1, 4):
        d.line([(kx * 480, 0), (kx * 480, H)], fill=(70, 70, 70))
    for ky in range(1, 4):
        d.line([(0, ky * 270), (W, ky * 270)], fill=(70, 70, 70))
    col = (0, 220, 0) if r["cls"] else (255, 70, 70)
    w0, w1, w2, w3 = r["win"]
    d.rectangle([w0 // 2, w2, w1 // 2, w3], outline=(255, 200, 0), width=2)   # 窗口
    if r["bb_win"]:
        bx0, bx1, by0, by1 = r["bb_win"]
        d.rectangle([bx0 // 2, by0, bx1 // 2, by1], outline=col, width=4)     # 前景 bbox
    name = ["未知", "圆", "矩形"][r["cls"]]
    d.text((20, H - 46), f"{name}  A={r['a_win']} fill={r['fill']:.2f} cg={r['cg']:.2f} "
                         f"grid={r['best']}  {r['why']}", fill=col, font=f)
    d.text((20, 12), f"mu={r['mu']} pol={r['pol']} (黄框=窗口, 绿/红=前景bbox)", fill=(220, 220, 220), font=f)
    out = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0] + ".png")
    canvas.save(out)
    return out


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "数据集"
    iters = 3
    if "--iters" in sys.argv:
        iters = int(sys.argv[sys.argv.index("--iters") + 1])
    files = []
    for e in ("*.jpg", "*.jpeg", "*.png", "*.bmp", "*.JPG", "*.PNG"):
        files += glob.glob(os.path.join(root, e))
    files = sorted(set(files))
    outdir = os.path.join(root, "eval_out_v2")
    os.makedirs(outdir, exist_ok=True)
    print("=" * 128)
    print(f"{'文件':34s} {'mu':>4s} {'pol':>3s} {'格':>10s} {'A':>7s} {'bbox':>10s} {'fill':>5s} {'cg':>5s}  判定 原因")
    print("=" * 128)
    rows = []
    for p in files:
        r = run(p, iters)
        annotate(p, r, outdir)
        rows.append(r | {"file": os.path.basename(p)})
    print("-" * 128)
    from collections import Counter
    c = Counter(r["cls"] for r in rows)
    print(f"共 {len(rows)} 张 ｜ 圆 {c[1]} ｜ 矩形 {c[2]} ｜ 未知 {c[0]}")
    csv = os.path.join(root, "eval_v2.csv")
    keys = ["file", "mu", "pol", "best", "cell_cnt", "a_win", "fill", "cg", "cls", "why"]
    with open(csv, "w", encoding="utf-8-sig") as fh:
        fh.write(",".join(keys) + "\n")
        for r in rows:
            fh.write(",".join(str(round(r.get(k, ""), 4)) if isinstance(r.get(k, ""), float)
                              else str(r.get(k, "")) for k in keys) + "\n")
    print(f"标注图 → {outdir}\n结果表 → {csv}")


if __name__ == "__main__":
    main()
