# -*- coding: utf-8 -*-
"""eval_edge_quality.py —— 边缘检测质量评估（RMSE / PSNR / SSIM / FOM）
   RTL 模型（edge_canny_2px）：
     高斯 3x3 带限 → Sobel → |G| = |Gx|+|Gy| → 4 方向 NMS → 局部阈值+双阈值 → 滞后
   参考真值：
     合成图（有精确形状）→ 形状边界（形态学梯度）
     实拍照片        → skimage.canny(σ=1.4, 低阈值) 作为代理真值
   指标：
     RMSE / PSNR / SSIM（二值边缘图，0/1）
     FOM = Pratt FOM，α=1/9，距离来自欧氏距离变换
"""
import glob
import os
import sys

import numpy as np
from scipy import ndimage as ndi
from skimage.feature import canny
from skimage.metrics import structural_similarity as ssim_fn
from PIL import Image

W, H = 1920, 1080


# ---------------------------------------------------------------- 工具
def load_gray(path):
    im = Image.open(path).convert("L")
    w, h = im.size
    if w * 9 > h * 16:
        nw = h * 16 // 9
        im = im.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    else:
        nh = w * 9 // 16
        im = im.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    return np.array(im.resize((W, H), Image.LANCZOS)).astype(np.float32)


def gauss3(img):
    k = np.array([[1., 2., 1.], [2., 4., 2.], [1., 2., 1.]]) / 16.
    return ndi.convolve(img, k, mode="nearest")


def sobel(img):
    kx = np.array([[-1., 0., 1.], [-2., 0., 2.], [-1., 0., 1.]])
    ky = np.array([[-1., -2., -1.], [0., 0., 0.], [1., 2., 1.]])
    return ndi.convolve(img, kx, mode="nearest"), ndi.convolve(img, ky, mode="nearest")


def nms(mag, gx, gy):
    """4 方向 NMS（0/45/90/135）"""
    ang = (np.rad2deg(np.arctan2(gy, gx)) + 180.0) % 180.0
    m = mag.copy()
    keep = np.zeros_like(mag, dtype=bool)
    q = np.pad(m, 1, mode="constant")
    c = q[1:-1, 1:-1]
    # 0°
    d0 = (ang < 22.5) | (ang >= 157.5)
    keep |= d0 & (c >= q[1:-1, 2:]) & (c >= q[1:-1, 0:-2])
    # 45°
    d45 = (ang >= 22.5) & (ang < 67.5)
    keep |= d45 & (c >= q[0:-2, 2:]) & (c >= q[2:, 0:-2])
    # 90°
    d90 = (ang >= 67.5) & (ang < 112.5)
    keep |= d90 & (c >= q[0:-2, 1:-1]) & (c >= q[2:, 1:-1])
    # 135°
    d135 = (ang >= 112.5) & (ang < 157.5)
    keep |= d135 & (c >= q[0:-2, 0:-2]) & (c >= q[2:, 2:])
    out = np.where(keep, m, 0.0)
    out[0, :] = 0; out[-1, :] = 0; out[:, 0] = 0; out[:, -1] = 0
    return out


def hysteresis(strong, weak):
    """8 连通滞后：弱边缘保留与强边缘连通的部分"""
    lb, n = ndi.label(weak, structure=np.ones((3, 3)))
    if n == 0:
        return strong.copy()
    keep = np.zeros(n + 1, dtype=bool)
    hit = np.unique(lb[strong])
    keep[hit] = True
    keep[0] = False
    return strong | keep[lb]


def rtl_canny(img, t1, t2_shift=2, local_shift=1, gauss_on=True, local_on=True):
    """RTL 口径：|G|=|Gx|+|Gy|，T1 全局，T2=T1>>t2_shift，局部阈值 ḡ>>local_shift"""
    g = gauss3(img) if gauss_on else img
    gx, gy = sobel(g)
    mag = np.abs(gx) + np.abs(gy)
    mag = nms(mag, gx, gy)
    # 局部背景均值（3x3）
    bg = ndi.uniform_filter(g, size=3)
    thr = np.full_like(mag, float(t1))
    if local_on:
        thr = np.maximum(thr, bg * 0.25)   # ḡ>>2 等效（局部阈值随亮度）
    strong = mag >= thr
    weak = mag >= (thr * (1.0 / (1 << t2_shift)))
    return hysteresis(strong, weak)


# ---------------------------------------------------------------- 指标
def fom(ref, test, alpha=1.0 / 9.0):
    """Pratt FOM；ref/test 为布尔边缘图"""
    if ref.sum() == 0 or test.sum() == 0:
        return 0.0
    d = ndi.distance_transform_edt(~ref)
    dd = d[test]
    return float(np.sum(1.0 / (1.0 + alpha * dd * dd)) / max(ref.sum(), test.sum()))


def metrics(ref, test):
    r = ref.astype(np.float32)
    t = test.astype(np.float32)
    mse = float(np.mean((r - t) ** 2))
    rmse = float(np.sqrt(mse))
    psnr = 99.0 if mse == 0 else float(10 * np.log10(1.0 / mse))
    try:
        ssim = float(ssim_fn(r, t, data_range=1.0))
    except Exception:
        ssim = 0.0
    return rmse, psnr, ssim, fom(ref, test)


def gt_from_mask(mask):
    """形状掩膜 → 边界真值"""
    er = ndi.binary_erosion(mask, np.ones((3, 3)))
    return mask & ~er


def main():
    root = "数据集"
    t1_list = [int(x) for x in (sys.argv[1].split(",") if len(sys.argv) > 1 else ["8", "12", "16", "24", "32"])]
    files = sorted(glob.glob(os.path.join(root, "0*.png"))) + sorted(glob.glob(os.path.join(root, "微信*.jpg")))[:6]
    print("=" * 96)
    print("边缘检测质量评估（合成图，真值=形状边界）")
    print("=" * 96)
    print(f"{'图':22s} {'T1':>4s} {'RMSE':>7s} {'PSNR':>7s} {'SSIM':>7s} {'FOM':>6s}")
    print("-" * 96)
    best = {}
    for p in files:
        g = load_gray(p)
        if p.endswith(".png"):
            mask = g < 110
            ref = gt_from_mask(mask)
        else:
            ref = canny(g, sigma=1.4, low_threshold=0.06, high_threshold=0.18)
        if ref.sum() < 500:
            continue
        for t1 in t1_list:
          for g_on in (True, False):
            test = rtl_canny(g, t1, gauss_on=g_on)
            rmse, psnr, ssim, f = metrics(ref, test)
            print(f"{os.path.basename(p)[:22]:22s} {t1:4d} g={int(g_on)} {rmse:7.4f} {psnr:7.2f} {ssim:7.4f} {f:6.3f}")
            k = os.path.basename(p)
            if k not in best or f > best[k][1]:
                best[k] = (t1, f, ssim)
    print("-" * 96)
    print("每图最优 FOM：")
    for k, v in best.items():
        print(f"  {k[:24]:24s} T1={v[0]:3d}  FOM={v[1]:.3f}  SSIM={v[2]:.3f}")


if __name__ == "__main__":
    main()
