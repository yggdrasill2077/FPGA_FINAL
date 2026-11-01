# -*- coding: utf-8 -*-
"""
评测 v4 —— 种子格 + bbox 跟踪窗（拟实现为 R11）
  1) 边框带判极性 pol（1 = 目标是暗的）
  2) 4×4 网格：每格统计【暗样本数 lo】和【亮样本数 hi】
     打分 score = lo  if hi*5 >= 2*格样本总数  else 0   ← "偏亮的格里那些暗块"
     选 score 最大的格作为【种子】
  3) 跟踪窗：第 0 帧用种子格 ± 半格；之后用【上一帧暗目标 bbox】扩大 15%
  4) 在窗内统计暗像素 → A/bbox/矩 → 填充度/宽高比/面积门控 → 分类
用法: python eval_shapes_v4.py [目录]
"""
import os, sys, glob, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
FONT = "C:/Windows/Fonts/msyh.ttc"
THRESH = 128
BBX_MAX, BBY_MAX = 1800, 1000
A_MIN, A_MAX, FILL_MIN = 150, 65530, 297
K_CIRC, K_RECT = 10616, 125112


def load_gray(path):
    # 中心裁剪到 16:9 后缩放（模拟 16:9 相机看到的画面，不补边、不拉伸）
    im = Image.open(path).convert("L")
    w, h = im.size
    if w * 9 > h * 16:          # 太宽 → 裁左右
        nw = h * 16 // 9
        im = im.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    else:                        # 太高 → 裁上下
        nh = w * 9 // 16
        im = im.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    return np.array(im.resize((W, H), Image.LANCZOS))


def bbox_of(m):
    ys, xs = np.nonzero(m)
    if len(xs) == 0:
        return None
    return int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())


def grow(bb, frac=0.15):
    x0, x1, y0, y1 = bb
    dx = max(6, int((x1 - x0) * frac)); dy = max(6, int((y1 - y0) * frac))
    return max(0, x0 - dx), min(W - 1, x1 + dx), max(0, y0 - dy), min(H - 1, y1 + dy)


def run(path, iters=4, verbose=True):
    g = load_gray(path).astype(np.int64)
    ys, xs = np.mgrid[0:H, 0:W]
    smp = (ys % 4 == 0) & (xs % 4 == 0)
    band = (xs < 96) | (xs >= W - 96) | (ys < 64) | (ys >= H - 64)
    n_hi = int(((g > THRESH) & smp & band).sum())
    n_lo = int(((g <= THRESH) & smp & band).sum())
    pol = 0 if n_hi <= n_lo else 1
    if pol == 0:
        obj, ref = (g > THRESH), (g <= THRESH)      # 亮目标
    else:
        obj, ref = (g <= THRESH), (g > THRESH)      # 暗目标（纸亮）

    cell = (ys // 270) * 4 + (xs // 480)
    lo = np.bincount(cell[obj & smp].ravel(), minlength=16).astype(np.int64)
    hi = np.bincount(cell[ref & smp].ravel(), minlength=16).astype(np.int64)
    tot = lo + hi
    score = np.where(hi * 5 >= 2 * tot, lo, 0)
    seed = int(score.argmax())
    bcx, bcy = seed % 4, seed // 4
    win = (max(0, bcx * 480 - 240), min(W - 1, bcx * 480 + 719),
           max(0, bcy * 270 - 135), min(H - 1, bcy * 270 + 404))

    bb = None
    for it in range(iters):
        x0, x1, y0, y1 = win
        m = obj & smp & (xs >= x0) & (xs <= x1) & (ys >= y0) & (ys <= y1)
        bb = bbox_of(m)
        if bb is None:
            break
        win = grow(bb)

    x0, x1, y0, y1 = win
    m = obj & smp & (xs >= x0) & (xs <= x1) & (ys >= y0) & (ys <= y1)
    a = int(m.sum())
    rej = []
    if a < A_MIN:
        rej.append(f"面积{a}")
    fill = cg = 0.0
    bw = bh = 0
    bb = bbox_of(m)
    if bb:
        bx0, bx1, by0, by1 = bb
        bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
        if bx0 == 0 or by0 == 0 or bx1 >= W - 1 or by1 >= H - 1:
            rej.append("触边")
        if bw > BBX_MAX or bh > BBY_MAX:
            rej.append(f"bbox{bw}x{bh}")
        fill = 16 * a / (bw * bh)
        if 16 * a * 1024 < FILL_MIN * bw * bh:
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
        circ = (a * K_CIRC >= m20 + m02)
        lq = max((m20 >> 4) * (m02 >> 4) - (m11 >> 4) ** 2, 0)
        rect = (lq <= K_RECT * a2)
        cg = 16 * a / (math.pi * ((m20 + m02) / 4096)) if (m20 + m02) else 0
        cls = 1 if circ else (2 if rect else 0)
        if cls == 0:
            rej.append("判据不符")
    if verbose:
        print(f"{os.path.basename(path)[:34]:34s} pol={pol} 种子={seed:2d}(lo={lo[seed]:5d},hi={hi[seed]:5d}) "
              f"A={a:6d} bbox={f'{bw}x{bh}':>9s} fill={fill:4.2f} cg={cg:4.2f} "
              f"→ {['未知','圆  ','矩形'][cls]} {','.join(rej)}")
    return dict(pol=pol, seed=seed, a=a, bb=bb, win=win, fill=fill, cg=cg,
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
    col = (0, 220, 0) if r["cls"] else (255, 70, 70)
    if r["bb"]:
        bx0, bx1, by0, by1 = r["bb"]
        d.rectangle([bx0 // 2, by0, bx1 // 2, by1], outline=col, width=4)
    d.text((16, H - 44), f"{['未知','圆','矩形'][r['cls']]} A={r['a']} fill={r['fill']:.2f} "
                         f"cg={r['cg']:.2f} 种子{r['seed']} {r['why']}", fill=col, font=f)
    out = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0] + ".png")
    canvas.save(out)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "数据集"
    files = []
    for e in ("*.jpg", "*.jpeg", "*.png", "*.bmp", "*.JPG"):
        files += glob.glob(os.path.join(root, e))
    files = sorted(set(files))
    outdir = os.path.join(root, "eval_out_v4")
    os.makedirs(outdir, exist_ok=True)
    print("=" * 138)
    print(f"{'文件':34s} {'pol':>3s} {'种子':>18s} {'A':>7s} {'bbox':>10s} {'fill':>5s} {'cg':>5s}  判定 原因")
    print("=" * 138)
    rows = []
    for p in files:
        r = run(p)
        annotate(p, r, outdir)
        rows.append(r)
    print("-" * 138)
    from collections import Counter
    c = Counter(r["cls"] for r in rows)
    print(f"共 {len(rows)} 张 ｜ 圆 {c[1]} ｜ 矩形 {c[2]} ｜ 未知 {c[0]}")
    print(f"标注图 → {outdir}")


if __name__ == "__main__":
    main()
