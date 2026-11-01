# -*- coding: utf-8 -*-
"""eval_v8_sweep.py -- F7 参数扫描（物理 18 张）"""
import itertools
import numpy as np
import eval_v2_paper as E
from eval_v5 import TRUTH, CLS_ID, photos
from eval_v6_ccl2 import build_templates, cell_grid

STY = build_templates()
PHYS = set([56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73])


def run(g, margin, dark, tham, tmin=0.29):
    x0 = int(E.W * margin); y0 = int(E.H * margin)
    lim = np.zeros_like(g, bool)
    lim[y0:E.H - y0, x0:E.W - x0] = True
    m = (g < dark) & lim
    if m.sum() < 200:
        return 0, {}
    ys, xs = np.nonzero(m)
    bb = (int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max()))
    bw, bh = bb[1] - bb[0] + 1, bb[3] - bb[2] + 1
    a = int(m[::4, ::4].sum())
    fill = a * 16 / (bw * bh)
    if fill < tmin or not (bw * 4 >= bh and bh * 4 >= bw):
        return 0, {}
    cnt, bw, bh = cell_grid(m, bb)
    thr = (bw * bh) // 2048
    obs = (cnt > thr).astype(np.uint8)
    ds = {k: E.ham(obs, v) for k, v in STY.items()}
    km = min(ds, key=ds.get)
    dmin = ds[km]
    cls = CLS_ID[km[-2] if km[0] == 'o' else km[0]] if dmin < tham else 0
    return cls, dict(dmin=dmin)


def main():
    ph = [(n, p) for n, p in photos() if n in PHYS]
    gs = [(n, E.load(p), TRUTH[n]) for n, p in ph]
    best = (0, None)
    for margin, dark, tham in itertools.product((0.05, 0.08, 0.11, 0.14),
                                               (95, 110, 125, 140),
                                               (180, 220, 256)):
        ok = 0
        for n, g, truth in gs:
            c, _ = run(g, margin, dark, tham)
            ok += (c == CLS_ID[truth])
        if ok > best[0]:
            best = (ok, (margin, dark, tham))
        print(f"margin={margin:.0%} dark={dark} tham={tham}: {ok}/18")
    print("-" * 50)
    print(f"BEST {best[0]}/18 = {best[0]/18:.1%} @ margin={best[1][0]:.0%} dark={best[1][1]} tham={best[1][2]}")


if __name__ == "__main__":
    main()
