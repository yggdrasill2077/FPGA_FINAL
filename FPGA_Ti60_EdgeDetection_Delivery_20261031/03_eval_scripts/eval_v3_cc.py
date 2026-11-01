# -*- coding: utf-8 -*-
"""eval_v3_cc.py —— 上限测试：纸内"最大暗连通块" + 模板分类（用真 CCL）"""
import glob
import numpy as np
from scipy import ndimage as ndi

import eval_v2_paper as E


def run(use_cc_paper=True, use_cc_obj=True, er_block=16):
    t = E.load_templates()
    files = sorted(glob.glob("数据集/微信*.jpg"))
    names = ["未知", "圆", "矩形", "三角", "十字"]
    ok = 0
    rows = []
    for i, p in enumerate(files):
        g = E.load(p)
        truth = E.LABELS[i]
        bb = E.paper_bbox_cc(g) if use_cc_paper else E.paper_bbox_erode(g, er_block)
        if bb is None:
            rows.append((i, truth, 0, dict(why="无纸")))
            continue
        x0, x1, y0, y1 = bb
        mx = int((x1 - x0) * E.MARGIN) + 4
        my = int((y1 - y0) * E.MARGIN) + 4
        sub = np.zeros_like(g, bool)
        sub[y0 + my:y1 - my + 1, x0 + mx:x1 - mx + 1] = True
        dark = (g < E.DARK_T) & sub
        mask = dark
        if use_cc_obj:
            lb, n = ndi.label(dark, structure=np.ones((3, 3)))
            if n == 0:
                rows.append((i, truth, 0, dict(why="无暗块")))
                continue
            sz = ndi.sum(dark, lb, range(1, n + 1))
            kk = int(np.argmax(sz)) + 1
            if sz[kk - 1] < 3000:
                rows.append((i, truth, 0, dict(why="块太小")))
                continue
            mask = (lb == kk)
        a = int(mask[::4, ::4].sum())
        if a < 150:
            rows.append((i, truth, 0, dict(why=f"A={a}")))
            continue
        ys, xs = np.nonzero(mask)
        bx0, bx1, by0, by1 = xs.min(), xs.max(), ys.min(), ys.max()
        bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
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
        rows.append((i, truth, cls, dict(a=a, bw=bw, bh=bh, fill=fill, dmin=dmin,
                                         tn=tn, good=good)))
    print("=" * 100)
    print(f"CCL 上限测试  paper_cc={use_cc_paper} obj_cc={use_cc_obj}")
    print("=" * 100)
    for i, truth, cls, info in rows:
        print(f"{i:3d} {truth:>8s} → {names[cls]:>4s}  bbox={info.get('bw',0)}x{info.get('bh',0)} "
              f"fill={info.get('fill',0):.2f} dmin={info.get('dmin',0):4d} {info.get('tn','')} "
              f"{'OK' if info.get('good') else '':>2s} {info.get('why','')}")
    print("-" * 100)
    print(f"正确 {ok}/{len(files)} = {ok/len(files):.1%}")
    return ok


if __name__ == "__main__":
    run()
