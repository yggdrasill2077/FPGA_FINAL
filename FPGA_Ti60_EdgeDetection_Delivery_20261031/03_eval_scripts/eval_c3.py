# -*- coding: utf-8 -*-
"""eval_c3.py —— C3: PDC-lite 学习式线性混合（5 折交叉拟合）
   特征 f = [|Gx|, |Gy|, max, min, |Lap4|, |Lap8|]（全部在 RTL 中可得）
   拟合：最小二乘 f·w ≈ 人类标注软边界
   评测：NMS → 双阈值滞后 → ODS/OIS/AP（与 C2 同口径）
"""
import sys
import numpy as np
from scipy import ndimage as ndi

import eval_bsds as B
import eval_bsds2 as B2

KX = np.array([[-1., 0., 1.], [-2., 0., 2.], [-1., 0., 1.]])
KY = np.array([[-1., -2., -1.], [0., 0., 0.], [1., 2., 1.]])
L4 = np.array([[0., 1., 0.], [1., -4., 1.], [0., 1., 0.]])
L8 = np.array([[1., 1., 1.], [1., -8., 1.], [1., 1., 1.]])
G3 = np.array([[1., 2., 1.], [2., 4., 2.], [1., 2., 1.]]) / 16.


def feats(img):
    g = ndi.convolve(img, G3, mode="nearest")
    gx = ndi.convolve(g, KX, mode="nearest")
    gy = ndi.convolve(g, KY, mode="nearest")
    ax, ay = np.abs(gx), np.abs(gy)
    lo = np.minimum(ax, ay)
    hi = np.maximum(ax, ay)
    l4 = np.abs(ndi.convolve(g, L4, mode="nearest"))
    l8 = np.abs(ndi.convolve(g, L8, mode="nearest"))
    F = np.stack([hi, lo, l4 * 0.5, l8 * 0.25], axis=-1)
    return F


def nms_from_mag(m, gx, gy):
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
    return out, gx, gy


def fit_weights(ids, sub=8):
    n = 4
    A = np.zeros((n, n)); b = np.zeros(n); cnt = 0
    for iid in ids:
        img = B.load_img(iid)
        gl = B.gt_for(iid)
        if not gl:
            continue
        gt = np.mean(gl, axis=0).astype(np.float32)
        F = feats(img)
        Fs = F[::sub, ::sub].reshape(-1, n)
        ys = gt[::sub, ::sub].reshape(-1)
        A += Fs.T @ Fs
        b += Fs.T @ ys
        cnt += Fs.shape[0]
    sc = np.sqrt(np.diag(A) / max(1, cnt)) + 1e-9
    A = A / np.outer(sc, sc); b = b / sc
    A += np.eye(n) * 1e-6
    w = np.linalg.solve(A, b)
    return w / sc


def eval_w(ids, w):
    mags, gts = [], []
    for iid in ids:
        img = B.load_img(iid)
        gl = B.gt_for(iid)
        if not gl:
            continue
        F = feats(img)
        m = (F * w[None, None, :]).sum(-1)
        m = np.maximum(m, 0)
        g = ndi.convolve(img, G3, mode="nearest")
        gx = ndi.convolve(g, KX, mode="nearest")
        gy = ndi.convolve(g, KY, mode="nearest")
        mn, _, _ = nms_from_mag(m, gx, gy)
        mags.append(mn)
        gts.append(gl)
    return B2.evaluate(mags, gts)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    ids = [l.strip() for l in open(B.BS + r"\iids_test.txt") if l.strip()][:n]
    folds = 5
    idx = np.array_split(np.arange(len(ids)), folds)
    allw = []
    ods, ois, ap = [], [], []
    for k in range(folds):
        te = [ids[int(i)] for i in idx[k]]
        tr = [ids[int(i)] for j in range(folds) if j != k for i in idx[j]]
        w = fit_weights(tr)
        allw.append(w)
        o, s2, a = eval_w(te, w)
        ods.append(o); ois.append(s2); ap.append(a)
        print(f"  fold{k+1}: ODS={o:.3f} OIS={s2:.3f} AP={a:.3f}  w={np.round(w,3)}")
    print("-" * 78)
    print(f"C3 5-fold: ODS={np.mean(ods):.3f} OIS={np.mean(ois):.3f} AP={np.mean(ap):.3f}")
    print("平均权重:", np.round(np.mean(allw, axis=0), 3))


if __name__ == "__main__":
    main()
