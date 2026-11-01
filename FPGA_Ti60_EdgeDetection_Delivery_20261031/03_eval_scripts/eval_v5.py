# -*- coding: utf-8 -*-
"""eval_v5.py —— 27 张实拍（18 旧 + 9 新）上对比两种方案
   A) 当前 F7：边带门控(8%) + 模板匹配
   B) CCL   ：亮区最大连通域 = 纸 → 纸内最大暗连通域 = 目标 → 模板匹配
标签按文件名末尾编号（"_NN_"）索引，与排序无关。
"""
import glob
import re
import numpy as np
from scipy import ndimage as ndi

import eval_v2_paper as E

# 编号 → 真值
TRUTH = {
    # 旧 18 张（21:15–21:16）
    56: "square", 57: "square", 58: "triangle", 59: "triangle",
    60: "circle", 61: "circle", 62: "circle", 63: "circle",
    64: "triangle", 65: "square", 66: "square", 67: "square",
    68: "circle", 69: "square", 70: "circle", 71: "triangle",
    72: "none", 73: "none",
    # 新 9 张（15:03–15:05，拍屏幕）
    74: "cross", 75: "triangle", 76: "triangle", 77: "square", 78: "square",
    79: "square", 80: "square", 81: "circle", 82: "circle",
}
NAMES = ["未知", "圆", "矩形", "三角", "十字"]
CLS_ID = {"circle": 1, "square": 2, "triangle": 3, "cross": 4, "none": 0}


def photos():
    out = []
    for p in sorted(glob.glob("数据集/微信*.jpg")):
        m = re.search(r"_(\d+)_1\.jpg$", p.rsplit("/", 1)[-1])
        if m and int(m.group(1)) in TRUTH:
            out.append((int(m.group(1)), p))
    return sorted(out)


def template_cls(mask, bb, t):
    bx0, bx1, by0, by1 = bb
    bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
    a = int(mask[::4, ::4].sum())
    if a < 150 or bw < 32 or bh < 32:
        return 0, dict(a=a, bw=bw, bh=bh, why="小")
    fill = a * 16 / (bw * bh)
    if fill < 0.29 or not (bw * 4 >= bh and bh * 4 >= bw):
        return 0, dict(a=a, bw=bw, bh=bh, fill=fill, why="形状门控")
    cnt, _, _ = E.cell_counts(mask, bx0, bx1, by0, by1)
    thr = (bw * bh) // 2048
    obs = (cnt > thr).astype(np.uint8)
    ds = {k: E.ham(obs, t[k]) for k in t}
    tn = min(ds, key=ds.get)
    dmin = ds[tn]
    cls = CLS_ID[tn[0]] if dmin < 256 else 0
    return cls, dict(a=a, bw=bw, bh=bh, fill=fill, dmin=dmin, tn=tn, why="" if cls else "dmin")


def method_A(g, t):
    x0 = int(E.W * 0.08); y0 = int(E.H * 0.08)
    lim = np.zeros_like(g, bool)
    lim[y0:E.H - y0, x0:E.W - x0] = True
    mask = (g < E.DARK_T) & lim
    if mask.sum() == 0:
        return 0, dict(why="空")
    ys, xs = np.nonzero(mask)
    bb = (xs.min(), xs.max(), ys.min(), ys.max())
    return template_cls(mask, bb, t)


def method_B(g, t):
    """CCL 版：亮区最大连通域→纸；纸内最大暗连通域→目标"""
    paper = (g > 175)
    lb, n = ndi.label(paper)
    if n == 0:
        return 0, dict(why="无纸")
    sz = ndi.sum(paper, lb, range(1, n + 1))
    k = int(np.argmax(sz)) + 1
    ys, xs = np.nonzero(lb == k)
    px0, px1, py0, py1 = xs.min(), xs.max(), ys.min(), ys.max()
    mx = int((px1 - px0) * 0.04) + 4
    my = int((py1 - py0) * 0.04) + 4
    sub = np.zeros_like(g, bool)
    sub[py0 + my:py1 - my + 1, px0 + mx:px1 - mx + 1] = True
    dark = (g < E.DARK_T) & sub
    lb2, n2 = ndi.label(dark, structure=np.ones((3, 3)))
    if n2 == 0:
        return 0, dict(why="无暗块")
    sz2 = ndi.sum(dark, lb2, range(1, n2 + 1))
    k2 = int(np.argmax(sz2)) + 1
    if sz2[k2 - 1] < 2000:
        return 0, dict(why="块太小")
    mask = (lb2 == k2)
    ys, xs = np.nonzero(mask)
    bb = (xs.min(), xs.max(), ys.min(), ys.max())
    return template_cls(mask, bb, t)


def main():
    t = E.load_templates()
    ph = photos()
    print("=" * 104)
    print(f"27 张实拍对比：A) 当前 F7 边带+模板   B) CCL 纸内最大暗块")
    print("=" * 104)
    print(f"{'编号':>4s} {'真值':>8s} | {'A 输出':>6s} {'dmin':>5s} | {'B 输出':>6s} {'dmin':>5s}")
    print("-" * 104)
    okA = okB = 0
    for num, p in ph:
        g = E.load(p)
        truth = TRUTH[num]
        ca, ia = method_A(g, t)
        cb, ib = method_B(g, t)
        okA += (ca == CLS_ID[truth])
        okB += (cb == CLS_ID[truth])
        print(f"{num:4d} {truth:>8s} | {NAMES[ca]:>6s} {ia.get('dmin',0):5d} | {NAMES[cb]:>6s} {ib.get('dmin',0):5d} "
              f"{'OK' if cb == CLS_ID[truth] else ''}")
    n = len(ph)
    print("-" * 104)
    print(f"A（当前 F7）: {okA}/{n} = {okA/n:.1%}")
    print(f"B（CCL）    : {okB}/{n} = {okB/n:.1%}")


if __name__ == "__main__":
    main()
