# -*- coding: utf-8 -*-
"""eval_v6_ccl2.py —— CCL v2：Otsu 自适应掩膜 + 最大连通域 + 双风格模板（实心/轮廓）
目标：在 27 张实拍上明显超过 51.9%（F7 基线）
"""
import glob
import numpy as np
from scipy import ndimage as ndi

import eval_v2_paper as E
from eval_v5 import TRUTH, NAMES, CLS_ID, photos

N = 32


def otsu(g):
    h = np.bincount(np.clip(g.ravel(), 0, 255), minlength=256).astype(np.float64)
    p = h / h.sum()
    w = np.cumsum(p)
    mu = np.cumsum(p * np.arange(256))
    mt = mu[-1]
    den = w * (1 - w)
    den[den == 0] = 1e-9
    sb = (mt * w - mu) ** 2 / den
    return int(np.argmax(sb))


def outline(t):
    """32x32 实心模板 → 轮廓模板"""
    er = ndi.binary_erosion(t, np.ones((3, 3)))
    return (t & ~er).astype(np.uint8)


def build_templates():
    t = E.load_templates()                  # {(cls,ang): 32x32 filled}
    full, outl = {}, {}
    for k, v in t.items():
        full[k] = (v > 0).astype(np.uint8)
        outl[("o",) + k] = outline((v > 0).astype(np.uint8))
    return {**full, **outl}


def cell_grid(mask, bb, n=N):
    bx0, bx1, by0, by1 = bb
    bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
    sub = mask[by0:by1 + 1, bx0:bx1 + 1]
    gx = (np.arange(bw) * n) // bw
    gy = (np.arange(bh) * n) // bh
    cnt = np.zeros((n, n), np.int32)
    idx = np.nonzero(sub)
    np.add.at(cnt, (gy[idx[0]], gx[idx[1]]), 1)
    return cnt, bw, bh


def method_ccl(g, t, blk=8, use_otsu=True, exclude_border=True):
    thr = otsu(g) if use_otsu else 110
    m = (g < thr) if use_otsu else (g < thr)
    # 1/8 降采样后做连通域（模拟 RTL 工作域）
    sm = m[::blk, ::blk]
    lb, n = ndi.label(sm, structure=np.ones((3, 3)))
    if n == 0:
        return 0, dict(why="无连通域")
    sz = ndi.sum(sm, lb, range(1, n + 1))
    # 排除触边的大块（背景）
    H2, W2 = sm.shape
    order = np.argsort(sz)[::-1]
    best = None
    for k in order[:12]:
        kk = int(k) + 1
        ys, xs = np.nonzero(lb == kk)
        if len(xs) < 8:
            break
        touch = (ys.min() == 0) or (xs.min() == 0) or (ys.max() == H2 - 1) or (xs.max() == W2 - 1)
        if exclude_border and touch and sz[k] > 0.15 * H2 * W2:
            continue                      # 大片且触边 → 背景
        best = (kk, ys, xs)
        break
    if best is None:
        return 0, dict(why="全是背景")
    kk, ys, xs = best
    bx0, bx1 = int(xs.min()) * blk, int((xs.max() + 1) * blk) - 1
    by0, by1 = int(ys.min()) * blk, int((ys.max() + 1) * blk) - 1
    bx1 = min(E.W - 1, bx1); by1 = min(E.H - 1, by1)
    bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
    if bw < 32 or bh < 32:
        return 0, dict(why=f"太小{bw}x{bh}")
    # 用全分辨率掩膜在该 bbox 内重算网格
    lim = np.zeros_like(m, bool)
    lim[by0:by1 + 1, bx0:bx1 + 1] = True
    mm = m & lim
    cnt, bw, bh = cell_grid(mm, (bx0, bx1, by0, by1))
    thr2 = (bw * bh) // 2048
    obs = (cnt > thr2).astype(np.uint8)
    ds = {k: E.ham(obs, v) for k, v in t.items()}
    kmin = min(ds, key=ds.get)
    dmin = ds[kmin]
    cls = CLS_ID[kmin[-2] if kmin[0] == "o" else kmin[0]] if dmin < 256 else 0
    return cls, dict(dmin=dmin, style=("outline" if kmin[0] == "o" else "filled"),
                     bw=bw, bh=bh, otsu=thr, why="" if cls else "dmin")


def main():
    t = build_templates()
    ph = photos()
    print("=" * 100)
    print(f"CCL v2（Otsu + 最大连通域 + 实心/轮廓双模板）  {len(ph)} 张")
    print("=" * 100)
    ok = 0
    for num, p in ph:
        g = E.load(p)
        truth = TRUTH[num]
        cls, info = method_ccl(g, t)
        good = (cls == CLS_ID[truth])
        ok += good
        print(f"{num:4d} {truth:>8s} → {NAMES[cls]:>4s} dmin={info.get('dmin',0):4d} "
              f"style={info.get('style',''):>7s} otsu={info.get('otsu',0):3d} "
              f"bbox={info.get('bw',0)}x{info.get('bh',0)} {'OK' if good else '':>2s} {info.get('why','')}")
    print("-" * 100)
    print(f"正确 {ok}/{len(ph)} = {ok/len(ph):.1%}   （F7 基线 14/27 = 51.9%）")


if __name__ == "__main__":
    main()
