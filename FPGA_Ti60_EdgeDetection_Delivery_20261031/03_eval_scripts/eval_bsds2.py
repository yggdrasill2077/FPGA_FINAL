# -*- coding: utf-8 -*-
"""eval_bsds2.py —— BSDS300 全量评测（含滞后连接）
   对每组参数：阈值 T_hi 扫描，T_lo = T_hi / hyst_ratio，做 8 连通滞后 → 二值边缘
   指标：ODS（全局最优 F）、OIS（每图最优 F 平均）、AP（PR 曲线面积）
"""
import sys
import numpy as np
from scipy import ndimage as ndi
from skimage.morphology import skeletonize

import eval_bsds as B


def hyst_binary(mag, t_hi, ratio=4.0):
    strong = mag >= t_hi
    if strong.sum() == 0:
        return strong
    weak = mag >= (t_hi / ratio)
    lb, n = ndi.label(weak, structure=np.ones((3, 3)))
    if n == 0:
        return strong
    keep = np.zeros(n + 1, dtype=bool)
    keep[np.unique(lb[strong])] = True
    keep[0] = False
    return keep[lb]


def evaluate(mags, gts, ratios=(2.0, 4.0), n_thr=12, thin=False, tol=None):
    thr_all = []
    for m in mags:
        v = m[m > 0].ravel()
        if v.size:
            thr_all.append(np.percentile(v, [55, 65, 75, 82, 87, 90, 92, 94, 95.5, 96.5, 97.5, 98.5]))
    if not thr_all:
        return 0.0, 0.0, 0.0
    thr = np.mean(np.array(thr_all), axis=0)
    best = (0.0, 0.0, 0.0)
    for rr in ratios:
        pr = np.zeros((len(thr), 3))
        per_img_best = []
        for m, gl in zip(mags, gts):
            gt = np.mean(gl, axis=0) > 0.5 if gl else None
            if gt is None or gt.sum() == 0:
                continue
            d_gt = ndi.distance_transform_edt(~gt)
            tl = (0.0075 * np.hypot(gt.shape[0], gt.shape[1])) if tol is None else tol
            bf = 0.0
            for i, t in enumerate(thr):
                e = hyst_binary(m, t, rr)
                if thin and e.any():
                    e = skeletonize(e)
                if e.sum() == 0:
                    continue
                d_me = ndi.distance_transform_edt(~e)
                p = float(np.mean(d_gt[e] <= tl))
                r = float(np.mean(d_me[gt] <= tl))
                pr[i, 0] += p; pr[i, 1] += r; pr[i, 2] += 1
                if p + r > 0:
                    bf = max(bf, 2 * p * r / (p + r))
            per_img_best.append(bf)
        n = max(1, pr[0, 2])
        P = pr[:, 0] / n; R = pr[:, 1] / n
        F = np.where(P + R > 0, 2 * P * R / np.maximum(P + R, 1e-9), 0)
        ods = float(F.max())
        ois = float(np.mean(per_img_best)) if per_img_best else 0.0
        order = np.argsort(R)
        ap = float(np.trapezoid(P[order], R[order])) if hasattr(np, "trapezoid") else float(np.trapz(P[order], R[order]))
        if ods > best[0]:
            best = (ods, ois, abs(ap))
    return best


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    ids = [l.strip() for l in open(B.BS + r"\iids_test.txt") if l.strip()][:n]
    print("=" * 90)
    print(f"BSDS300 test {len(ids)} 张（人类真值，含滞后 T_lo=T_hi/2 与 /4）")
    print("=" * 90)
    print(f"{'配置':26s} {'ODS':>6s} {'OIS':>6s} {'AP':>6s}")
    print("-" * 90)
    cfg = [("P1 Sobel no-thin", "C0", True, False),
           ("P1 Sobel +thin",   "C0", True, True),
           ("P2 C1 +thin",      "C1", True, True),
           ("P2 C2 +thin",      "C2", True, True)]
    for name, comp, gs, th in cfg:
        mags, gts = [], []
        for iid in ids:
            img = B.load_img(iid)
            g = B.gt_for(iid)
            if not g:
                continue
            mags.append(B.mag_map(img, comp, gs))
            gts.append(g)
        ods, ois, ap = evaluate(mags, gts, thin=th)
        print(f"{name:26s} {ods:6.3f} {ois:6.3f} {ap:6.3f}")


if __name__ == "__main__":
    main()
