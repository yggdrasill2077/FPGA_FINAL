# -*- coding: utf-8 -*-
"""
eval_current.py —— 用当前 RTL 算法（F6 口径）评测数据集
  掩膜   : mask = Y < min(max_y - 60, 110)     （F2/F2b）
  统计   : 1/16 抽样，全画面（无窗口，F1）
  门控   : 触边 / bbox 上限 / 填充度 0.29 / 宽高比 4 / 格计数 150 / 面积占比 0.2%~50%
  分类   : 32×32 格 → thr=bw*bh/2048 → 16 模板汉明 → min<THAM(256)
用法: python eval_current.py <图片目录> [...]
"""
import os
import sys
import glob
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v6_edge', 'sim'))
from gen_tmpl_frames import load_templates, cell_counts, ham   # noqa: E402

W, H = 1920, 1080
TY_MARGIN, TY_CAP = 60, 110
THAM, TMPL_MIN = 256, 32
FILL_MIN, CELL_MIN, BBX, BBY = 297, 150, 1800, 1000


def load_gray(path):
    im = Image.open(path).convert("L")
    w, h = im.size
    if w * 9 > h * 16:
        nw = h * 16 // 9
        im = im.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    else:
        nh = w * 9 // 16
        im = im.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    return np.array(im.resize((W, H), Image.LANCZOS))


def run(path, t):
    g = load_gray(path).astype(np.int32)
    max_y = g[::4, ::4].max()
    ty = min(int(max_y) - TY_MARGIN, TY_CAP)
    mask = g < ty

    # 1/16 抽样统计（RTL：row%4==0 且 x%4==0）
    smp = mask[::4, ::4]
    a = int(smp.sum())
    if a == 0:
        return dict(name=os.path.basename(path), a=0, ty=ty, cls=0, why="无前景")
    ys, xs = np.nonzero(smp)
    bx0, bx1 = int(xs.min()) * 4, int(xs.max()) * 4
    by0, by1 = int(ys.min()) * 4, int(ys.max()) * 4
    bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
    why = []
    if bx0 == 0 or by0 == 0 or bx1 >= W - 4 or by1 >= H - 4:
        why.append("触边")
    if bw > BBX or bh > BBY:
        why.append("bbox大")
    fill = 16 * a / (bw * bh)
    if 16 * a * 1024 < FILL_MIN * bw * bh:
        why.append("fill")
    if not (bw * 4 >= bh and bh * 4 >= bw):
        why.append("aspect")
    if a < CELL_MIN:
        why.append(f"面积{a}")
    frac = a / (W * H / 16)
    if frac < 0.002 or frac > 0.5:
        why.append(f"占比{frac:.1%}")

    cls = 0
    dmin = 9999
    tname = ""
    if not why:
        cnt, _, _ = cell_counts(mask, bx0, bx1, by0, by1)
        thr = (bw * bh) // 2048
        obs = (cnt > thr).astype(np.uint8)
        ds = {k: ham(obs, t[k]) for k in t}
        tname = min(ds, key=ds.get)
        dmin = ds[tname]
        if dmin < THAM and bw >= TMPL_MIN and bh >= TMPL_MIN:
            cls = ["circle", "square", "triangle", "cross"].index(tname[0]) + 1
        else:
            why.append(f"dmin={dmin}")
    return dict(name=os.path.basename(path), a=a, ty=ty, bw=bw, bh=bh, fill=fill,
                cls=cls, dmin=dmin, tname=tname, why=",".join(why))


def main():
    roots = sys.argv[1:] or ["数据集"]
    files = []
    for r in roots:
        for e in ("*.jpg", "*.jpeg", "*.png"):
            files += glob.glob(os.path.join(r, e))
    files = sorted(set(files))
    t = load_templates()
    print("=" * 104)
    print(f"当前算法（F6 口径）评测：{len(files)} 张")
    print("=" * 104)
    print(f"{'文件':34s} {'ty':>4s} {'A':>6s} {'bbox':>10s} {'fill':>5s} {'dmin':>5s} {'结果':>9s}  原因")
    print("-" * 104)
    from collections import Counter
    C = Counter()
    for p in files:
        r = run(p, t)
        C[r["cls"]] += 1
        bbox = f"{r.get('bw',0)}x{r.get('bh',0)}"
        name = ["未知", "圆", "矩形", "三角", "十字"][r["cls"]] if r["cls"] else "未知"
        print(f"{r['name'][:34]:34s} {r['ty']:4d} {r['a']:6d} {bbox:>10s} "
              f"{r.get('fill',0):5.2f} {r.get('dmin',0):5d} {name:>9s}  {r['why']}")
    print("-" * 104)
    print(f"合计：圆 {C[1]} ｜ 矩形 {C[2]} ｜ 三角 {C[3]} ｜ 十字 {C[4]} ｜ 未知 {C[0]}")


if __name__ == "__main__":
    main()
