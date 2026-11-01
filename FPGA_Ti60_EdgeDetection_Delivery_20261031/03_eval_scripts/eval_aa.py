# -*- coding: utf-8 -*-
"""eval_aa.py —— 亚像素抗锯齿渲染验证（1-D 逐行，阶梯边缘）
   每行：真实边界位置 xs(y)（小数）
     A. 二值渲染：边界像素取整数列 → 阶梯误差
     B. 亚像素 AA：抛物线 δ 估计（用梯度幅值 x-1,x,x+1）→ 强度 (1-|δ|, |δ|) 分给两列
   指标：每行渲染质心 vs 真实位置 → RMS / max 误差（px）
"""
import numpy as np

W = 256
H = 256


def step_image(angle_deg, ss=8):
    """左黑右白的阶梯图（超采样抗锯齿），返回 (img, 每行真实边界 x)"""
    th = np.deg2rad(angle_deg)
    yy, xx = np.mgrid[0:H * ss, 0:W * ss]
    xx = xx / ss + 0.5 / ss
    yy = yy / ss + 0.5 / ss
    xs = 128.0 + (yy - 128.0) * np.tan(th)          # 每行真实边界
    img = np.where(xx < xs, 0.0, 255.0)
    img = img.reshape(H, ss, W, ss).mean(axis=(1, 3))
    xs_row = 128.0 + (np.arange(H) + 0.5 - 128.0) * np.tan(th)
    return img.astype(np.float32), xs_row


def row_edge(img):
    """逐行：返回 (整数列 xint, 亚像素 xsub, 幅度)"""
    g = np.abs(np.diff(img, axis=1))                # 水平梯度，长度 W-1，对应 x+0.5
    out = []
    for y in range(H):
        gv = g[y]
        x = int(np.argmax(gv))
        l = gv[x - 1] if x > 0 else 0.0
        c = gv[x]
        r = gv[x + 1] if x + 1 < len(gv) else 0.0
        den = (l - 2 * c + r)
        d = 0.5 * (l - r) / den if abs(den) > 1e-6 else 0.0
        d = float(np.clip(d, -0.5, 0.5))
        out.append((x + 0.5, x + 0.5 + d, c))
    return out


def main():
    print("=" * 78)
    print("亚像素抗锯齿渲染验证（阶梯边缘，256x256）")
    print("=" * 78)
    print(f"{'角度':>6s} {'二值 RMS':>10s} {'二值 max':>9s} {'AA RMS':>9s} {'AA max':>8s} {'误差降幅':>9s}")
    print("-" * 78)
    rows = []
    for ang in (5, 10, 15, 22, 30, 45):
        img, xs = step_image(ang)
        e = row_edge(img)
        y0, y1 = 32, 224
        eb, ea = [], []
        for y in range(y0, y1):
            xint, xsub, mag = e[y]
            if mag < 8:
                continue
            eb.append(xint - xs[y])
            ea.append(xsub - xs[y])
        eb = np.array(eb); ea = np.array(ea)
        rb = float(np.sqrt((eb ** 2).mean())); rbm = float(np.abs(eb).max())
        ra = float(np.sqrt((ea ** 2).mean())); ram = float(np.abs(ea).max())
        imp = (rb - ra) / rb * 100 if rb > 0 else 0
        print(f"{ang:6d} {rb:10.3f} {rbm:9.3f} {ra:9.3f} {ram:8.3f} {imp:8.1f}%")
        rows.append((ang, rb, ra))
    print("-" * 78)
    mb = np.mean([r[1] for r in rows]); ma = np.mean([r[2] for r in rows])
    print(f"平均：二值 {mb:.3f} px → 亚像素 {ma:.3f} px（改善 {(mb-ma)/mb*100:.1f}%）")
    print("=" * 78)


if __name__ == "__main__":
    main()
