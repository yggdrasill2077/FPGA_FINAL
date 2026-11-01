# -*- coding: utf-8 -*-
"""eval_v7_q4.py -- 1/4 域 CCL + 全分辨率模板：验证 DDR 方案是否可行"""
import glob, re
import numpy as np
from scipy import ndimage as ndi
import eval_v2_paper as E
from eval_v5 import TRUTH, NAMES, CLS_ID, photos
from eval_v6_ccl2 import build_templates, cell_grid

STY = build_templates()
PHYS = [56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73]
BLK = 4          # 1/4 域


def run_one(g, use_margin_only):
    # 标定纸/暗阈值（与 F7/离线一致）
    paper = (g > 150)
    lb, n = ndi.label(paper)
    if n == 0:
        return 0, {}
    sz = ndi.sum(paper, lb, range(1, n + 1))
    k = int(np.argmax(sz)) + 1
    ys, xs = np.nonzero(lb == k)
    px0, px1, py0, py1 = xs.min(), xs.max(), ys.min(), ys.max()
    mx = int((px1 - px0) * 0.04) + 4
    my = int((py1 - py0) * 0.04) + 4
    sub = np.zeros_like(g, bool)
    sub[py0 + my:py1 - my + 1, px0 + mx:px1 - mx + 1] = True
    dark = (g < 110) & sub

    # 1/4 域连通域（模拟 DDR 标签图）
    sm = dark[::BLK, ::BLK]
    lb2, n2 = ndi.label(sm, structure=np.ones((3, 3)))
    if n2 == 0:
        return 0, {}
    sz2 = ndi.sum(sm, lb2, range(1, n2 + 1))
    k2 = int(np.argmax(sz2)) + 1
    ys, xs = np.nonzero(lb2 == k2)
    bx0 = max(0, int(xs.min()) * BLK); bx1 = min(E.W - 1, (int(xs.max()) + 1) * BLK - 1)
    by0 = max(0, int(ys.min()) * BLK); by1 = min(E.H - 1, (int(ys.max()) + 1) * BLK - 1)
    bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
    if bw < 32 or bh < 32:
        return 0, {}
    # 全分辨率模板（用掩膜在该 bbox 内）
    lim = np.zeros_like(g, bool)
    lim[by0:by1 + 1, bx0:bx1 + 1] = True
    m = dark & lim
    cnt, bw, bh = cell_grid(m, (bx0, bx1, by0, by1))
    thr = (bw * bh) // 2048
    obs = (cnt > thr).astype(np.uint8)
    ds = {k: E.ham(obs, v) for k, v in STY.items()}
    km = min(ds, key=ds.get)
    dmin = ds[km]
    cls = CLS_ID[km[-2] if km[0] == 'o' else km[0]] if dmin < 256 else 0
    return cls, dict(dmin=dmin, bw=bw, bh=bh)


def main():
    ok = 0; okp = 0; np_ = 0
    for num, p in photos():
        g = E.load(p)
        truth = TRUTH[num]
        cls, info = run_one(g, False)
        good = (cls == CLS_ID[truth])
        ok += good
        if num in PHYS:
            np_ += 1; okp += good
        print(f"{num:4d} {truth:>8s} → {NAMES[cls]:>4s} dmin={info.get('dmin',0):4d} "
              f"bbox={info.get('bw',0)}x{info.get('bh',0)} {'OK' if good else ''}")
    print("-" * 60)
    print(f"1/4 域: 全部 {ok}/27 = {ok/27:.1%} ｜ 物理 18 张 {okp}/{np_} = {okp/max(1,np_):.1%}")


if __name__ == "__main__":
    main()
