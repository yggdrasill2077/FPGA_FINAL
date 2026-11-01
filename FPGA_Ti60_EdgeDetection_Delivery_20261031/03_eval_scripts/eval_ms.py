# -*- coding: utf-8 -*-
"""eval_ms.py —— A1 多尺度融合离线验证
   尺度1: 高斯3x3 一次 (σ≈0.75) → Sobel → |G|（含 C1+C2 补偿）
   尺度2: 高斯3x3 两次 (σ≈1.06) → Sobel → |G|
   融合: max / m1+γm2
   评测: NMS(方向取尺度1) → 双阈值滞后 → ODS/OIS/AP（与 C2 同口径）
"""
import sys
import numpy as np
from scipy import ndimage as ndi

import eval_bsds as B
import eval_bsds2 as B2

KX = np.array([[-1., 0., 1.], [-2., 0., 2.], [-1., 0., 1.]])
KY = np.array([[-1., -2., -1.], [0., 0., 0.], [1., 2., 1.]])
G3 = np.array([[1., 2., 1.], [2., 4., 2.], [1., 2., 1.]]) / 16.


def scale_mag(g):
    gx = ndi.convolve(g, KX, mode="nearest")
    gy = ndi.convolve(g, KY, mode="nearest")
    ax, ay = np.abs(gx), np.abs(gy)
    m = np.maximum(ax, ay) + 0.5 * np.minimum(ax, ay)      # C1
    lap = ndi.laplace(m)                                   # C2：G' = G + 0.25(4G-S) = 2G - S/4
    m = np.maximum(m - 0.25 * lap, 0.0)
    return m, gx, gy


def nms(m, gx, gy):
    ang = (np.rad2deg(np.arctan2(gy, gx)) + 180.0) % 180.0
    q = np.pad(m, 1, mode="constant")
    c = q[1:-1, 1:-1]
    keep = np.zeros_like(m, dtype=bool)
    d0 = (ang < 22.5) | (ang >= 157.5); keep |= d0 & (c >= q[1:-1, 2:]) & (c >= q[1:-1, 0:-2])
    d45 = (ang >= 22.5) & (ang < 67.5); keep |= d45 & (c >= q[0:-2, 2:]) & (c >= q[2:, 0:-2])
    d90 = (ang >= 67.5) & (ang < 112.5); keep |= d90 & (c >= q[0:-2, 1:-1]) & (c >= q[2:, 1:-1])
    d135 = (ang >= 112.5) & (ang < 157.5); keep |= d135 & (c >= q[0:-2, 0:-2]) & (c >= q[2:, 2:])
    out = np.where(keep, m, 0.0)
    out[0, :] = 0; out[-1, :] = 0; out[:, 0] = 0; out[:, -1] = 0
    return out


def run(img, mode, gamma=1.0, depth=1):
    g1 = img
    for _ in range(depth):
        g1 = ndi.convolve(g1, G3, mode="nearest")
    g2 = ndi.convolve(g1, G3, mode="nearest")
    m1, gx, gy = scale_mag(g1)
    m2, _, _ = scale_mag(g2)
    if mode == "s1":
        m = m1
    elif mode == "max":
        m = np.maximum(m1, m2)
    elif mode == "sum":
        m = m1 + gamma * m2
    elif mode == "s2":
        m = m2
    return nms(m, gx, gy)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    ids = [l.strip() for l in open(B.BS + r"\iids_test.txt") if l.strip()][:n]
    print("=" * 74)
    print(f"A1 多尺度融合（BSDS300 test {len(ids)} 张，人类真值）")
    print("=" * 74)
    print(f"{'配置':22s} {'ODS':>6s} {'OIS':>6s} {'AP':>6s}")
    print("-" * 74)
    for name, mode, dp in (("高斯级联 1 次", "s1", 1),
                          ("高斯级联 2 次", "s1", 2),
                          ("高斯级联 3 次", "s1", 3),
                          ("高斯级联 4 次", "s1", 4),
                          ("融合 max (1+2)", "max", 1)):
        mags, gts = [], []
        for iid in ids:
            img = B.load_img(iid)
            gl = B.gt_for(iid)
            if not gl:
                continue
            mags.append(run(img, mode, depth=dp))
            gts.append(gl)
        o, s, a = B2.evaluate(mags, gts)
        print(f"{name:22s} {o:6.3f} {s:6.3f} {a:6.3f}")


if __name__ == "__main__":
    main()
