# -*- coding: utf-8 -*-
"""eval_bsds.py —— 在 BSDS300 上用人类真值评测边缘质量（ODS/OIS/AP/FOM）
   .seg 格式：每行 "label row c0 c1" 的水平游程 → 还原标签图 → 边界 = 标签变化处
   指标：
     ODS = 阈值扫描下 PR 曲线的最大 F
     OIS = 每图最优 F 的平均
     AP  = PR 曲线下面积（梯形法）
     FOM = Pratt（最优阈值下）
   匹配容差 2 px（近似 BSDS 的 0.0075*diag）
"""
import glob
import os
import sys

import numpy as np
from scipy import ndimage as ndi
from PIL import Image

BS = r"D:\fpga\test\BSDS300-images\BSDS300"
HUM = r"D:\fpga\test\BSDS300-human\BSDS300\human"


def parse_seg(path):
    W = H = 0
    runs = []
    with open(path, "r", errors="ignore") as f:
        lines = f.read().split("\n")
    for ln in lines:
        p = ln.split()
        if not p:
            continue
        if p[0] == "width":
            W = int(p[1])
        elif p[0] == "height":
            H = int(p[1])
        elif p[0] == "data":
            idx = lines.index(ln)
            runs = [x.split() for x in lines[idx + 1:] if len(x.split()) == 4]
            break
    lab = np.zeros((H, W), np.int32)
    for r in runs:
        try:
            lb, row, c0, c1 = int(r[0]), int(r[1]), int(r[2]), int(r[3])
        except Exception:
            continue
        if 0 <= row < H:
            lab[row, max(0, c0):min(W, c1 + 1)] = lb
    return lab


def boundary_from_labels(lab):
    b = np.zeros_like(lab, dtype=bool)
    b[:, 1:] |= lab[:, 1:] != lab[:, :-1]
    b[1:, :] |= lab[1:, :] != lab[:-1, :]
    return b


def gt_for(iid):
    maps = []
    for sub in ("color", "gray"):
        for p in glob.glob(os.path.join(HUM, sub, "*", str(iid) + ".seg")):
            lab = parse_seg(p)
            if lab.size:
                maps.append(boundary_from_labels(lab))
    return maps


def load_img(iid):
    p = os.path.join(BS, "images", "test", str(iid) + ".jpg")
    return np.array(Image.open(p).convert("L")).astype(np.float32)


def mag_map(img, comp="C0", gauss=True, alpha=0.25):
    g = img
    if gauss:
        k = np.array([[1., 2., 1.], [2., 4., 2.], [1., 2., 1.]]) / 16.
        g = ndi.convolve(g, k, mode="nearest")
    kx = np.array([[-1., 0., 1.], [-2., 0., 2.], [-1., 0., 1.]])
    ky = np.array([[-1., -2., -1.], [0., 0., 0.], [1., 2., 1.]])
    gx = ndi.convolve(g, kx, mode="nearest")
    gy = ndi.convolve(g, ky, mode="nearest")
    ax, ay = np.abs(gx), np.abs(gy)
    if comp == "C0":
        m = ax + ay
    else:
        m = np.maximum(ax, ay) + 0.5 * np.minimum(ax, ay)
        if comp == "C2":
            lap = ndi.laplace(m)
            m = m - alpha * (-lap)
            m = np.maximum(m, 0)
    # NMS
    ang = (np.rad2deg(np.arctan2(gy, gx)) + 180.0) % 180.0
    q = np.pad(m, 1, mode="constant")
    c = q[1:-1, 1:-1]
    keep = np.zeros_like(m, dtype=bool)
    d0 = (ang < 22.5) | (ang >= 157.5)
    keep |= d0 & (c >= q[1:-1, 2:]) & (c >= q[1:-1, 0:-2])
    d45 = (ang >= 22.5) & (ang < 67.5)
    keep |= d45 & (c >= q[0:-2, 2:]) & (c >= q[2:, 0:-2])
    d90 = (ang >= 67.5) & (ang < 112.5)
    keep |= d90 & (c >= q[0:-2, 1:-1]) & (c >= q[2:, 1:-1])
    d135 = (ang >= 112.5) & (ang < 157.5)
    keep |= d135 & (c >= q[0:-2, 0:-2]) & (c >= q[2:, 2:])
    out = np.where(keep, m, 0.0)
    out[0, :] = 0; out[-1, :] = 0; out[:, 0] = 0; out[:, -1] = 0
    return out


def pr_at(mag, gt, t, tol=2.0):
    """距离容差的 precision/recall（近似 BSDS 的 correspondence）"""
    d_gt = ndi.distance_transform_edt(~gt)
    d_me = ndi.distance_transform_edt(~(mag >= t))
    det = mag >= t
    if det.sum() == 0 or gt.sum() == 0:
        return 0.0, 0.0, 0.0
    prec = float(np.mean(d_gt[det] <= tol))
    rec = float(np.mean(d_me[gt] <= tol))
    f = 0.0 if prec + rec == 0 else 2 * prec * rec / (prec + rec)
    return prec, rec, f


def evaluate(mags, gts, nt=16):
    """mags: list of magnitude maps; gts: list of list of GT maps"""
    thr = np.percentile(np.concatenate([m[m > 0].ravel() for m in mags if (m > 0).any()]), [50, 60, 70, 80, 85, 90, 92, 94, 95, 96, 97, 98, 99, 99.5])
    ois = []
    pr_all = []
    for m, g_list in zip(mags, gts):
        gt = np.mean(g_list, axis=0) > 0.5 if g_list else None
        if gt is None or gt.sum() == 0:
            continue
        best_f = 0.0
        for t in thr:
            _, _, f = pr_at(m, gt, t)
            best_f = max(best_f, f)
        ois.append(best_f)
        for t in thr:
            p, r, _ = pr_at(m, gt, t)
            pr_all.append((p, r))
    if not pr_all:
        return 0, 0, 0
    pr_all = np.array(pr_all)
    # ODS：把所有图所有阈值的 (p,r) 聚合成一个 PR 曲线（近似做法：按阈值分箱平均）
    n = len(ois)
    ods = 0.0
    for i in range(nt):
        sel = pr_all[i::nt]
        if len(sel) == 0:
            continue
        p = sel[:, 0].mean(); r = sel[:, 1].mean()
        if p + r > 0:
            ods = max(ods, 2 * p * r / (p + r))
    # AP：按 recall 排序的精度积分
    order = np.argsort(pr_all[:, 1])
    r = pr_all[order, 1]; p = pr_all[order, 0]
    ap = float(np.trapezoid(p, r)) if hasattr(np, "trapezoid") else float(np.trapz(p, r))
    return ods, float(np.mean(ois)), abs(ap)


def main():
    n_img = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    ids = [l.strip() for l in open(os.path.join(BS, "iids_test.txt")) if l.strip()][:n_img]
    print("=" * 92)
    print(f"BSDS300 test 前 {len(ids)} 张（人类真值 .seg）")
    print("=" * 92)
    print(f"{'通路':18s} {'ODS':>6s} {'OIS':>6s} {'AP':>6s}")
    print("-" * 92)
    for name, comp, gauss in (("P1 Sobel|1-norm", "C0", False),
                              ("P2 C1 max+0.5min", "C1", True),
                              ("P2 C1 no-gauss", "C1", False),
                              ("P2 C2 +lap(a=.25)", "C2", True)):
        mags, gts = [], []
        for iid in ids:
            img = load_img(iid)
            g = gt_for(iid)
            if not g:
                continue
            mags.append(mag_map(img, comp, gauss))
            gts.append(g)
        ods, ois, ap = evaluate(mags, gts)
        print(f"{name:18s} {ods:6.3f} {ois:6.3f} {ap:6.3f}")


if __name__ == "__main__":
    main()
