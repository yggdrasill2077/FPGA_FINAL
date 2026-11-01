# -*- coding: utf-8 -*-
"""
eval_v2_paper.py —— "先找白纸，再在纸内找暗块" 离线评测（目标 ≥10/18）
真值（人工标注 18 张实拍）：
  圆   : 04 05 06 07 12 14
  方   : 00 01 09 10
  矩形 : 11 13        （模板集无"矩形"类，判为方/矩形均算对）
  三角 : 02 03 08 15
  无   : 16 17        （应判未知）
"""
import os
import sys
import glob
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'v6_edge', 'sim'))
from gen_tmpl_frames import load_templates, cell_counts, ham   # noqa

W, H = 1920, 1080
LABELS = {
    0: "square", 1: "square", 2: "triangle", 3: "triangle",
    4: "circle", 5: "circle", 6: "circle", 7: "circle",
    8: "triangle", 9: "square", 10: "square", 11: "square", 12: "circle",
    13: "square", 14: "circle", 15: "triangle", 16: "none", 17: "none",
}
PAPER_T = 175      # 纸判定：Y > PAPER_T
DARK_T = 110       # 暗目标：Y < DARK_T
MARGIN = 0.04      # 纸内缩进


def load(path):
    im = Image.open(path).convert("L")
    w, h = im.size
    if w * 9 > h * 16:
        nw = h * 16 // 9
        im = im.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    else:
        nh = w * 9 // 16
        im = im.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    return np.array(im.resize((W, H), Image.LANCZOS)).astype(np.int32)


def paper_bbox_erode(g, blk=16, er=1):
    """RTL 可实现的便宜版：1/16 降采样 + 3x3 腐蚀 → 最大亮块 bbox"""
    paper = (g > PAPER_T)
    sm = paper[::blk, ::blk]
    for _ in range(er):
        sm = ndi.binary_erosion(sm, structure=np.ones((3, 3)))
    if sm.sum() < 4:
        return None
    ys, xs = np.nonzero(sm)
    # 腐蚀把边界收缩了 er*blk，扩回来
    x0 = max(0, xs.min() * blk - er * blk); x1 = min(W - 1, (xs.max() + 1) * blk + er * blk)
    y0 = max(0, ys.min() * blk - er * blk); y1 = min(H - 1, (ys.max() + 1) * blk + er * blk)
    return x0, x1, y0, y1


def paper_bbox_cc(g):
    """参考版：最大亮连通域 bbox（离线基准，RTL 不一定能做到）"""
    paper = (g > PAPER_T)
    lb, n = ndi.label(paper)
    if n == 0:
        return None
    sz = ndi.sum(paper, lb, range(1, n + 1))
    k = int(np.argmax(sz)) + 1
    ys, xs = np.nonzero(lb == k)
    return int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())


def classify_object(g, bb, t, verbose=False):
    x0, x1, y0, y1 = bb
    mx = int((x1 - x0) * MARGIN) + 4
    my = int((y1 - y0) * MARGIN) + 4
    x0, x1, y0, y1 = x0 + mx, x1 - mx, y0 + my, y1 - my
    if x1 <= x0 or y1 <= y0:
        return 0, dict(why="纸内无区域")
    sub = np.zeros_like(g, bool)
    sub[y0:y1 + 1, x0:x1 + 1] = True
    mask = (g < DARK_T) & sub

    a = int(mask[::4, ::4].sum())
    if a < 150:
        return 0, dict(why=f"无暗块(A={a})", a=a)
    ys, xs = np.nonzero(mask)
    bx0, bx1, by0, by1 = xs.min(), xs.max(), ys.min(), ys.max()
    bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
    fill = a * 16 / (bw * bh)
    why = []
    if bx0 == 0 or by0 == 0 or bx1 >= W - 4 or by1 >= H - 4:
        why.append("触边")
    if bw > 1800 or bh > 1000:
        why.append("bbox大")
    if fill < 0.29:
        why.append("fill")
    if not (bw * 4 >= bh and bh * 4 >= bw):
        why.append("aspect")

    cnt, _, _ = cell_counts(mask, bx0, bx1, by0, by1)
    thr = (bw * bh) // 2048
    obs = (cnt > thr).astype(np.uint8)
    ds = {k: ham(obs, t[k]) for k in t}
    tname = min(ds, key=ds.get)
    dmin = ds[tname]
    cls = 0
    if not why and dmin < 256 and bw >= 32 and bh >= 32:
        cls = ["circle", "square", "triangle", "cross"].index(tname[0]) + 1
    if cls == 0 and not why:
        why.append(f"dmin={dmin}")
    return cls, dict(a=a, bw=bw, bh=bh, fill=fill, dmin=dmin, tname=tname,
                     why=",".join(why), bbox=(bx0, bx1, by0, by1))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "erode"
    t = load_templates()
    files = sorted(glob.glob("数据集/微信*.jpg"))
    names = ["未知", "圆", "矩形", "三角", "十字"]
    ok = 0
    print("=" * 118)
    print(f"白纸定位法评测（mode={mode}）  PAPER_T={PAPER_T} DARK_T={DARK_T}")
    print("=" * 118)
    print(f"{'#':>3s} {'真值':>8s} {'纸bbox':>26s} {'A':>6s} {'bbox':>10s} {'fill':>5s} {'dmin':>5s} {'输出':>6s}  {'结果':>6s}  原因")
    print("-" * 118)
    for i, p in enumerate(files):
        g = load(p)
        bb = paper_bbox_erode(g) if mode == "erode" else paper_bbox_cc(g)
        truth = LABELS[i]
        if bb is None:
            cls, info = 0, dict(why="找不到白纸")
        else:
            cls, info = classify_object(g, bb, t)
        out = names[cls]
        good = ((truth == "circle" and cls == 1) or
                (truth in ("square",) and cls == 2) or
                (truth == "triangle" and cls == 3) or
                (truth == "none" and cls == 0))
        ok += good
        print(f"{i:3d} {truth:>8s} {str(bb):>26s} {info.get('a',0):6d} "
              f"{str(info.get('bw',0))+'x'+str(info.get('bh',0)):>10s} "
              f"{info.get('fill',0):5.2f} {info.get('dmin',0):5d} {out:>6s}  {'OK' if good else 'X':>6s}  {info.get('why','')}")
    print("-" * 118)
    print(f"正确 {ok}/{len(files)} = {ok/len(files):.1%}")


if __name__ == "__main__":
    main()
