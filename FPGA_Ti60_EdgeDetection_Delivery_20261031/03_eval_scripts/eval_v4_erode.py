# -*- coding: utf-8 -*-
"""eval_v4_erode.py —— 便宜版：暗掩膜 1/8 域腐蚀 → bbox → 全分辨率模板分类
   RTL 成本：3×3 腐蚀（240×135 域，需 2 行采样缓存）+ bbox 累加器 ≈ 150 LUT、0 RAM
"""
import glob
import numpy as np
from scipy import ndimage as ndi

import eval_v2_paper as E

BLK = 8          # 1/8 域
ER = 2           # 腐蚀次数


def run(blk=BLK, er=ER, paper_mode="erode"):
    t = E.load_templates()
    files = sorted(glob.glob("数据集/微信*.jpg"))
    names = ["未知", "圆", "矩形", "三角", "十字"]
    ok = 0
    rows = []
    for i, p in enumerate(files):
        g = E.load(p)
        truth = E.LABELS[i]
        # 1) 纸 bbox（便宜版）
        bb = E.paper_bbox_erode(g, 16, 1) if paper_mode == "erode" else E.paper_bbox_cc(g)
        if bb is None:
            rows.append((i, truth, 0, dict(why="无纸")))
            continue
        x0, x1, y0, y1 = bb
        mx = int((x1 - x0) * E.MARGIN) + 4
        my = int((y1 - y0) * E.MARGIN) + 4
        sub = np.zeros_like(g, bool)
        sub[max(0, y0 + my):y1 - my + 1, max(0, x0 + mx):x1 - mx + 1] = True
        dark = (g < E.DARK_T) & sub

        # 2) 1/8 域腐蚀 → bbox
        sm = dark[::blk, ::blk]
        sm2 = sm.copy()
        for _ in range(er):
            sm2 = ndi.binary_erosion(sm2, structure=np.ones((3, 3)))
        if sm2.sum() < 4:
            rows.append((i, truth, 0, dict(why="腐蚀后无块")))
            continue
        ys, xs = np.nonzero(sm2)
        bx0 = max(0, xs.min() * blk - er * blk); bx1 = min(E.W - 1, (xs.max() + 1) * blk + er * blk)
        by0 = max(0, ys.min() * blk - er * blk); by1 = min(E.H - 1, (ys.max() + 1) * blk + er * blk)
        bw, bh = bx1 - bx0 + 1, by1 - by0 + 1

        # 3) 全分辨率暗掩膜（限制在该 bbox 内）
        lim = np.zeros_like(g, bool)
        lim[by0:by1 + 1, bx0:bx1 + 1] = True
        mask = dark & lim
        a = int(mask[::4, ::4].sum())
        if a < 150:
            rows.append((i, truth, 0, dict(why=f"A={a}")))
            continue
        fill = a * 16 / (bw * bh)
        cnt, _, _ = E.cell_counts(mask, bx0, bx1, by0, by1)
        thr = (bw * bh) // 2048
        obs = (cnt > thr).astype(np.uint8)
        ds = {k: E.ham(obs, t[k]) for k in t}
        tn = min(ds, key=ds.get)
        dmin = ds[tn]
        cls = ["circle", "square", "triangle", "cross"].index(tn[0]) + 1 if dmin < 256 else 0
        if not (bw * 4 >= bh and bh * 4 >= bw):
            cls = 0
        if fill < 0.29:
            cls = 0
        good = ((truth == "circle" and cls == 1) or (truth == "square" and cls == 2)
                or (truth == "triangle" and cls == 3) or (truth == "none" and cls == 0))
        ok += good
        rows.append((i, truth, cls, dict(a=a, bw=bw, bh=bh, fill=fill, dmin=dmin, tn=tn,
                                         good=good)))
    print("=" * 100)
    print(f"便宜版（1/{blk} 腐蚀×{er}，纸定位={paper_mode}）")
    print("=" * 100)
    for i, truth, cls, info in rows:
        print(f"{i:3d} {truth:>8s} → {names[cls]:>4s}  bbox={info.get('bw',0)}x{info.get('bh',0)} "
              f"fill={info.get('fill',0):.2f} dmin={info.get('dmin',0):4d} {str(info.get('tn','')):16s} "
              f"{'OK' if info.get('good') else '':>2s} {info.get('why','')}")
    print("-" * 100)
    print(f"正确 {ok}/{len(files)} = {ok/len(files):.1%}")
    return ok


if __name__ == "__main__":
    for blk in (8, 16):
        for er in (1, 2, 3):
            print()
            run(blk, er)
