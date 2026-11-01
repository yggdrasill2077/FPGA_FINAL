# -*- coding: utf-8 -*-
"""eval_ms2.py —— A1 多尺度融合 / 高斯级联深度 离线验证（BSDS300 test 全 100 张）

在 eval_ms.py 基础上改造（scale_mag / nms 沿用其实现），评测口径与 eval_bsds.py /
eval_bsds2.py 完全一致（--verify 逐位校验：C0/C1/C2 三档 maxdiff = 0.00e+00）：
    C1 = max(|Gx|,|Gy|) + 0.5·min(|Gx|,|Gy|)
    C2 补偿两种历史写法：
        minus = G - 0.25·lap = 2G - S/4   （eval_ms.py 原写法，锐化）
        plus  = G + 0.25·lap = S/4        （eval_bsds.mag_map(alpha=.25) 原写法，邻域平均）
    → NMS(4 方向量化) → 双阈值滞后 T_lo=T_hi/2 与 T_hi/4 → ODS / OIS / AP
    容差 0.0075·diag，thin=False；thr 取各图 m[m>0] 百分位 [55..98.5] 的跨图均值

实验组：
    A 基线复算：P1(C0 |Gx|+|Gy|) / C1 无补偿 / C2 基线
    B 级联深度扫描：gauss3x3 连做 k=1..7 次（σ≈0.75√k，即 0.75/1.06/1.30/1.50/1.68/1.84/1.98）
    C 融合（最优两尺度）：max / m1+0.5m2 / m1+1.0m2 / sqrt(m1²+m2²)
    D 方向来源：NMS 方向取细尺度 vs 粗尺度
    E 参考：旧 (1,2) 组合、跨尺度融合、C2 后置

统计：OIS 给 ±标准误（n=100）；ODS/AP 走 5 折（折内聚合 P/R 再取 F）给 mean±std。

用法：
    python eval_ms2.py --verify                       # 校验评测器与原脚本一致
    python eval_ms2.py --jobs 10 --c2 plus  --json _ms2_results_plus.json
    python eval_ms2.py --jobs 10 --c2 minus --json _ms2_results_minus.json
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
import time

import numpy as np
from scipy import ndimage as ndi

import eval_bsds as B
import eval_bsds2 as B2

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "_ms2_gtcache.npz")

KX = np.array([[-1., 0., 1.], [-2., 0., 2.], [-1., 0., 1.]])
KY = np.array([[-1., -2., -1.], [0., 0., 0.], [1., 2., 1.]])
G3 = np.array([[1., 2., 1.], [2., 4., 2.], [1., 2., 1.]]) / 16.

PCTS = [55, 65, 75, 82, 87, 90, 92, 94, 95.5, 96.5, 97.5, 98.5]   # 与 eval_bsds2 一致
RATIOS = (2.0, 4.0)
N_FOLD = 5
MAXK = 7


def sigma(k):
    """k 次级联 3x3 高斯的等效 σ（按任务口径 σ≈0.75√k）"""
    return 0.75 * np.sqrt(k)


# ----------------------------------------------------------------------------- 算子
def smooth(g):
    """3x3 高斯 [1,2,1;2,4,2;1,2,1]/16，单次 σ≈0.75"""
    return ndi.convolve(g, G3, mode="nearest")


def c2_apply(m, mode):
    """C2 拉普拉斯补偿：minus → 2G-S/4（锐化）；plus → S/4（邻域平均）；none → 不补偿"""
    if mode == "none":
        return m
    lap = ndi.laplace(m)
    if mode == "minus":
        return np.maximum(m - 0.25 * lap, 0.0)
    if mode == "plus":
        return np.maximum(m + 0.25 * lap, 0.0)
    raise ValueError(mode)


def scale_mag(g, c2="minus", comp="c1"):
    """单尺度：comp='c1' → max+0.5·min（C1）；comp='c0' → |Gx|+|Gy|（P1）；再叠 C2"""
    gx = ndi.convolve(g, KX, mode="nearest")
    gy = ndi.convolve(g, KY, mode="nearest")
    ax, ay = np.abs(gx), np.abs(gy)
    m = (ax + ay) if comp == "c0" else (np.maximum(ax, ay) + 0.5 * np.minimum(ax, ay))
    return c2_apply(m, c2), gx, gy


def nms(m, gx, gy):
    """4 方向量化 NMS（与 eval_bsds.mag_map / eval_ms.nms 一致）"""
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


# ----------------------------------------------------------------------------- 配置
def cfg_single(name, depth, c2="minus", comp="c1"):
    return dict(name=name, kind="single", da=depth, db=depth, fuse="single",
                gamma=0.0, dir=depth, c2=c2, c2post=False, comp=comp)


def cfg_fuse(name, da, db, fuse, gamma=1.0, dir_depth=None, c2="minus", c2post=False, comp="c1"):
    return dict(name=name, kind="fuse", da=da, db=db, fuse=fuse, gamma=gamma,
                dir=da if dir_depth is None else dir_depth, c2=c2, c2post=c2post, comp=comp)


def cfg_sep(name, sigma, taps, c2="plus", comp="c1", q=None):
    """单次可分离高斯（taps 抽头）——用来检验"级联 k 次"能否用一个大核一次实现"""
    return dict(name=name, kind="sep", da=1, db=1, fuse="single", gamma=0.0, dir=1,
                c2=c2, c2post=False, comp=comp, sigma=sigma, taps=taps, q=q)


def sep_kernel(sigma, taps, q=None):
    """一维高斯抽头；q 给定时按 /q 整数定点量化（模拟 RTL 乘法）"""
    r = np.arange(taps) - (taps - 1) / 2.0
    k = np.exp(-(r * r) / (2.0 * sigma * sigma))
    if q:
        k = np.maximum(np.round(k / k.sum() * q), 0).astype(np.float64)
    return k / k.sum()


def sep_apply(img, k):
    return ndi.convolve1d(ndi.convolve1d(img, k, axis=0, mode="nearest"), k, axis=1, mode="nearest")


def mag_for(img, cfg):
    """按配置从原图算 NMS 后的幅值图（只算用到的尺度）"""
    if cfg["kind"] == "sep":
        g = sep_apply(img, sep_kernel(cfg["sigma"], cfg["taps"], cfg.get("q")))
        m, gx, gy = scale_mag(g, cfg["c2"], cfg.get("comp", "c1"))
        return nms(m, gx, gy)
    need = {cfg["da"], cfg["db"], cfg["dir"]}
    pyr = {0: img}
    g = img
    for d in range(1, max(need) + 1):
        g = smooth(g)
        pyr[d] = g
    sc = {d: scale_mag(pyr[d], "none" if cfg["c2post"] else cfg["c2"], cfg.get("comp", "c1"))
          for d in need}
    m = sc[cfg["da"]][0]
    if cfg["kind"] == "fuse":
        m2 = sc[cfg["db"]][0]
        if cfg["fuse"] == "max":
            m = np.maximum(m, m2)
        elif cfg["fuse"] == "lin":
            m = m + cfg["gamma"] * m2
        elif cfg["fuse"] == "sqrt":
            m = np.sqrt(m * m + m2 * m2)
        else:
            raise ValueError(cfg["fuse"])
    if cfg["c2post"]:
        m = c2_apply(m, cfg["c2"])
    _, gx, gy = sc[cfg["dir"]]
    return nms(m, gx, gy)


# ----------------------------------------------------------------------------- 真值缓存
def build_cache(ids, path=CACHE):
    """缓存 GT 与 d_gt²（uint16 整数：比较 d<=tol ⇔ d²<=tol²，避免 uint8 截断误差）"""
    gts, ds, tol = [], [], []
    t0 = time.time()
    for iid in ids:
        gl = B.gt_for(iid)
        gt = (np.mean(gl, axis=0) > 0.5) if gl else None
        if gt is None or not gt.any():
            raise RuntimeError("无真值: %s" % iid)
        d = ndi.distance_transform_edt(~gt)
        gts.append(gt)
        ds.append(np.rint(d * d).clip(0, 65535).astype(np.uint16))
        tol.append(0.0075 * np.hypot(gt.shape[0], gt.shape[1]))
    # BSDS300 test 含竖构图（如 78004 为 481x321）→ 形状逐图不同，扁平存储 + 形状表
    np.savez_compressed(path, ids=np.array([str(i) for i in ids]),
                        gt=np.concatenate([g.ravel() for g in gts]),
                        d2=np.concatenate([d.ravel() for d in ds]),
                        shape=np.array([g.shape for g in gts], np.int32),
                        tol=np.array(tol, np.float64))
    print("[cache] %d 张 GT/d_gt 写入 %s（%.1fs）"
          % (len(ids), os.path.basename(path), time.time() - t0), flush=True)


_G = {}


def _init(cache_path):
    d = np.load(cache_path)
    shapes = d["shape"]
    offs = np.concatenate([[0], np.cumsum([int(np.prod(s)) for s in shapes])])
    _G["ids"] = [str(x) for x in d["ids"]]
    _G["gt"] = [d["gt"][offs[k]:offs[k + 1]].reshape(tuple(shapes[k])) for k in range(len(shapes))]
    _G["d2"] = [d["d2"][offs[k]:offs[k + 1]].reshape(tuple(shapes[k])) for k in range(len(shapes))]
    _G["tol"] = d["tol"]
    _G["pos"] = {iid: k for k, iid in enumerate(_G["ids"])}


# ----------------------------------------------------------------------------- 单体评测
# 本沙箱禁止进程间管道（multiprocessing.Pool 直接 PermissionError），故用线程池按图并行：
# scipy.ndimage 的 C 实现释放 GIL，实测 8 线程 ≈ 5.8×，且结果与串行逐位一致
def _mag_pct(cfg, iid):
    m = mag_for(B.load_img(iid), cfg)
    v = m[m > 0].ravel()
    return m, (np.percentile(v, PCTS) if v.size else None)


def eval_one(cfg, ids, jobs=1):
    """一个配置在一组图上的完整评测（两遍：定阈值 → 累积 P/R）"""
    gtA, d2A, tolA, pos = _G["gt"], _G["d2"], _G["tol"], _G["pos"]

    # pass1：跨图百分位阈值；幅值图留内存（100 张 ≈ 60 MB），省一次重算
    with ThreadPoolExecutor(jobs) as ex:
        res = list(ex.map(lambda iid: _mag_pct(cfg, iid), ids))
    mags = [r[0] for r in res]
    pcts = [r[1] for r in res if r[1] is not None]
    thr = np.mean(np.array(pcts), axis=0)
    nthr = len(thr)

    def _pr(jj):
        j, iid = jj
        k = pos[iid]
        gt, d2, tl = gtA[k], d2A[k], tolA[k]
        m = mags[j]
        out = {}
        for rr in RATIOS:
            acc = np.zeros((nthr, 3))
            bf = 0.0
            for i, t in enumerate(thr):
                e = B2.hyst_binary(m, t, rr)
                if e.sum() == 0:
                    continue
                d_me = ndi.distance_transform_edt(~e)
                pp = float(np.mean(d2[e] <= tl * tl))
                rc = float(np.mean(d_me[gt] <= tl))
                acc[i, 0] = pp; acc[i, 1] = rc; acc[i, 2] = 1.0
                if pp + rc > 0:
                    bf = max(bf, 2 * pp * rc / (pp + rc))
            out[rr] = (acc, bf)
        return j % N_FOLD, out

    # pass2：滞后 + PR
    with ThreadPoolExecutor(jobs) as ex:
        rows = list(ex.map(_pr, list(enumerate(ids))))

    pr = {rr: np.zeros((nthr, 3)) for rr in RATIOS}
    prf = {rr: np.zeros((N_FOLD, nthr, 3)) for rr in RATIOS}
    fbest = {rr: np.zeros(len(ids)) for rr in RATIOS}
    for j, (fold, out) in enumerate(rows):
        for rr in RATIOS:
            acc, bf = out[rr]
            pr[rr] += acc
            prf[rr][fold] += acc
            fbest[rr][j] = bf

    def _metrics(acc):
        """acc:(nthr,3) → (ODS, AP)，n 取 thr0 的计数（与 eval_bsds2.evaluate 对齐）"""
        n = max(1.0, acc[0, 2])
        P = acc[:, 0] / n
        R = acc[:, 1] / n
        F = np.where(P + R > 0, 2 * P * R / np.maximum(P + R, 1e-9), 0.0)
        order = np.argsort(R)
        ap = float(np.trapezoid(P[order], R[order])) if hasattr(np, "trapezoid") \
            else float(np.trapz(P[order], R[order]))
        return float(F.max()), abs(ap)

    best = None
    for rr in RATIOS:
        ods, ap = _metrics(pr[rr])
        if best is None or ods > best["ods"]:
            f = np.array(fbest[rr])
            fold_ods, fold_ap, fold_ois = [], [], []
            for k in range(N_FOLD):
                o_f, a_f = _metrics(prf[rr][k])
                fold_ods.append(o_f)
                fold_ap.append(a_f)
                fold_ois.append(float(f[k::N_FOLD].mean()) if f[k::N_FOLD].size else 0.0)
            best = dict(name=cfg["name"], cfg=cfg, ratio=rr, ods=ods, ap=ap,
                        ois=float(f.mean()), ois_se=float(f.std(ddof=1) / np.sqrt(len(f))),
                        ois_std=float(f.std(ddof=1)),
                        f_img=[round(float(x), 6) for x in f],
                        fold_ods=fold_ods, fold_ap=fold_ap, fold_ois=fold_ois,
                        ods_fold_mean=float(np.mean(fold_ods)),
                        ods_fold_std=float(np.std(fold_ods, ddof=1)),
                        ap_fold_mean=float(np.mean(fold_ap)),
                        ap_fold_std=float(np.std(fold_ap, ddof=1)),
                        ois_fold_mean=float(np.mean(fold_ois)),
                        ois_fold_std=float(np.std(fold_ois, ddof=1)),
                        n=len(ids))
    return best


# ----------------------------------------------------------------------------- 驱动
def run_configs(cfgs, ids, jobs):
    if "gt" not in _G:
        _init(CACHE)
    out = []
    t0 = time.time()
    for c in cfgs:
        r = eval_one(c, ids, jobs)
        out.append(r)
        print("  [%4.0fs] %-24s ODS=%.3f OIS=%.3f AP=%.3f"
              % (time.time() - t0, r["name"], r["ods"], r["ois"], r["ap"]), flush=True)
    out.sort(key=lambda r: -r["ods"])
    return out


def fmt_row(r):
    return ("| %-22s | %.3f | %.3f ± %.3f | %.3f | %.3f ± %.3f | %.3f ± %.3f |"
            % (r["name"], r["ods"], r["ois"], r["ois_se"], r["ap"],
               r["ods_fold_mean"], r["ods_fold_std"], r["ap_fold_mean"], r["ap_fold_std"]))


HDR = ("| 配置 | ODS | OIS(±SE) | AP | ODS 5折 | AP 5折 |\n"
       "|---|---|---|---|---|---|")


def verify():
    """校验：缓存+线程版评测与 eval_bsds2.evaluate 逐位一致"""
    ids = [l.strip() for l in open(os.path.join(B.BS, "iids_test.txt")) if l.strip()][:10]
    if not os.path.exists(CACHE):
        build_cache(ids)
    _init(CACHE)
    ok = True
    cases = [("C0", "C0", cfg_single("vC0", 1, "none", "c0")),
             ("C1", "C1", cfg_single("vC1", 1, "none", "c1")),
             ("C2+", "C2", cfg_single("vC2p", 1, "plus", "c1")),
             ("C2-", None, cfg_single("vC2m", 1, "minus", "c1"))]
    pts = [B.gt_for(i) for i in ids]
    for tag, ref_comp, cfg in cases:
        if ref_comp is None:      # minus 口径无 B.mag_map 参照，只打印
            r = eval_one(cfg, ids, 1)
            print("VERIFY %-4s (无参照) ODS=%.4f OIS=%.4f AP=%.4f" % (tag, r["ods"], r["ois"], r["ap"]))
            continue
        mags = [B.mag_map(B.load_img(i), ref_comp, True) for i in ids]
        ref = B2.evaluate(mags, pts)
        mine = eval_one(cfg, ids, 1)
        d = max(abs(ref[0] - mine["ods"]), abs(ref[1] - mine["ois"]), abs(ref[2] - mine["ap"]))
        print("VERIFY %-8s ref=(%.4f,%.4f,%.4f) mine=(%.4f,%.4f,%.4f) maxdiff=%.2e %s"
              % (tag, ref[0], ref[1], ref[2], mine["ods"], mine["ois"], mine["ap"], d,
                 "OK" if d < 5e-3 else "FAIL"), flush=True)
        ok &= d < 5e-3
    print("VERIFY =>", "PASS" if ok else "FAIL")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--jobs", type=int, default=8, help="线程数（按图并行）")
    ap.add_argument("--json", default=os.path.join(HERE, "_ms2_results.json"))
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--c2", default="plus", choices=["minus", "plus"])
    args = ap.parse_args()

    if args.verify:
        verify()
        return

    ids = [l.strip() for l in open(os.path.join(B.BS, "iids_test.txt")) if l.strip()][:args.n]
    need_rebuild = (not os.path.exists(CACHE)) or \
                   ([str(x) for x in np.load(CACHE)["ids"]] != ids)
    if need_rebuild:
        build_cache(ids)

    c2 = args.c2
    ctag = "-" if c2 == "minus" else "+"
    print("=" * 104)
    print("A1 多尺度 / 级联深度验证 —— BSDS300 test %d 张（人类真值，容差 0.0075·diag，thin=False）"
          % len(ids))
    print("主口径 C2 = %s（%s）"
          % (c2, "minus: 2G-S/4 锐化" if c2 == "minus" else "plus: S/4 邻域平均"))
    print("=" * 104, flush=True)

    # ---- A/B：基线 + 级联深度扫描 k=1..7（两种 C2 口径都扫）
    g_base = [cfg_single("P1 C0 1k", 1, "none", "c0"),
              cfg_single("C1 1k 无补偿", 1, "none", "c1")]
    g_minus = [cfg_single("C1+C2- %dk" % k, k, "minus") for k in range(1, MAXK + 1)]
    g_plus = [cfg_single("C1+C2+ %dk" % k, k, "plus") for k in range(1, MAXK + 1)]
    g_abl = [cfg_single("无C2 %dk" % k, k, "none") for k in (2, 3, 5, 7)]
    print("\n[1/2] 基线 + 高斯级联深度扫描 k=1..%d" % MAXK, flush=True)
    r1 = run_configs(g_base + g_minus + g_plus + g_abl, ids, args.jobs)
    bn = {r["name"]: r for r in r1}

    # ---- 选最优两尺度（主口径内按 ODS 排序取前二）
    casc = [bn[c["name"]] for c in (g_minus if c2 == "minus" else g_plus)]
    casc.sort(key=lambda r: (-r["ods"], -r["ap"]))
    da, db = sorted([casc[0]["cfg"]["da"], casc[1]["cfg"]["da"]])
    print("\n  → 最优两尺度：%dk (ODS %.3f) 与 %dk (ODS %.3f)"
          % (da, bn["C1+C2%s %dk" % (ctag, da)]["ods"],
             db, bn["C1+C2%s %dk" % (ctag, db)]["ods"]), flush=True)

    # ---- C/D/E：融合 + 方向来源 + 参考组
    tag = "%d,%d" % (da, db)
    g_fuse = [cfg_fuse("融合 max(%s)" % tag, da, db, "max", c2=c2),
              cfg_fuse("融合 m%d+0.5m%d" % (da, db), da, db, "lin", gamma=0.5, c2=c2),
              cfg_fuse("融合 m%d+1.0m%d" % (da, db), da, db, "lin", gamma=1.0, c2=c2),
              cfg_fuse("融合 sqrt(m%d^2+m%d^2)" % (da, db), da, db, "sqrt", c2=c2)]
    g_dir = [cfg_fuse("融合 max(%s) 粗方向" % tag, da, db, "max", dir_depth=db, c2=c2),
             cfg_fuse("融合 m%d+1.0m%d 粗方向" % (da, db), da, db, "lin", gamma=1.0,
                      dir_depth=db, c2=c2)]
    g_ref = [cfg_fuse("融合 max(1,2) [旧]", 1, 2, "max", c2=c2),
             cfg_fuse("融合 m%d+1.0m1 跨尺度" % db, 1, db, "lin", gamma=1.0, c2=c2),
             cfg_fuse("融合 m%d+1.0m%d C2后置" % (da, db), da, db, "lin", gamma=1.0,
                      c2=c2, c2post=True)]
    print("\n[2/2] 多尺度融合 + 方向来源", flush=True)
    r2 = run_configs(g_fuse + g_dir + g_ref, ids, args.jobs)
    r2n = {r["name"]: r for r in r2}

    # ---- 汇总
    print("\n" + "=" * 104)
    print("A. 基线与级联深度扫描（C1+C2 → NMS → 双阈滞后）")
    print(HDR)
    for c in g_base + g_minus + g_plus + g_abl:
        print(fmt_row(bn[c["name"]]))
    print("\nB. 多尺度融合（主口径最优两尺度 %dk / %dk）" % (da, db))
    print(HDR)
    for c in g_fuse + g_dir + g_ref:
        print(fmt_row(r2n[c["name"]]))
    print("=" * 104)

    base = bn["C1+C2%s 1k" % ctag]
    best_single = max(casc, key=lambda r: r["ods"])
    best_fuse = max([r2n[c["name"]] for c in g_fuse], key=lambda r: r["ods"])
    print("基线 %s: ODS %.3f OIS %.3f AP %.3f"
          % (base["name"], base["ods"], base["ois"], base["ap"]))
    for lbl, r in (("最优单尺度", best_single), ("最优融合  ", best_fuse)):
        print("%s %-14s ODS %.3f (%+.3f) OIS %.3f (%+.3f) AP %.3f (%+.1f%%)"
              % (lbl, r["name"], r["ods"], r["ods"] - base["ods"], r["ois"],
                 r["ois"] - base["ois"], r["ap"], 100 * (r["ap"] / base["ap"] - 1)))
    print("判定门槛（对基线）：ODS >= %.3f 或 AP >= %.3f   → 最优单尺度 %s / 最优融合 %s"
          % (base["ods"] + 0.02, base["ap"] * 1.10,
             "达标" if (best_single["ods"] - base["ods"] >= 0.02 or best_single["ap"] >= base["ap"] * 1.10) else "未达标",
             "达标" if (best_fuse["ods"] - base["ods"] >= 0.02 or best_fuse["ap"] >= base["ap"] * 1.10) else "未达标"))

    allr = r1 + r2
    payload = dict(n=len(ids), c2=c2, ids=ids, base=base["name"], pair=[da, db],
                   best=best_single["name"], best_fuse=best_fuse["name"],
                   results=[{k: v for k, v in r.items() if k != "cfg"} for r in allr])
    with open(args.json, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    print("结果已写 %s" % args.json)


if __name__ == "__main__":
    main()
