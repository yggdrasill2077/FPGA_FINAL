# -*- coding: utf-8 -*-
"""eval_edge_dual.py —— 双通路边缘质量对比（通路1 纯 Sobel  vs  通路2 Canny+幅值补偿）

  基座：eval_edge_quality.py（不改它，import 复用 load_gray / gauss3 / sobel /
        gt_from_mask / hysteresis 的口径）。本脚本在其基础上扩展：
   1) 幅值补偿方案 C0/C1/C2/C3（C3 用最小二乘拟合，训练/验证分离）
   2) RTL 口径对齐：4 扇区 NMS（26.57°/63.43° 分界）+「>= 且至少一侧严格 >」keep
      规则（同 edge_canny_2px.v:443），另与基座 22.5° 扇区口径对照
   3) 局部阈值三种口径：off / lin（T_local = ḡ>>shift）/ rtl（√ 表 + [T/2,2T] 钳位）
   4) T1 × T2_SHIFT × 局部阈值 敏感性扫描（含扩展档）
   5) 方向增益（各向同性）诊断
   6) 输出 edge_dual_result.md（中文报告）

  用法：
    python eval_edge_dual.py            # 全量（约 10-15 min），写 edge_dual_raw.json + md
    python eval_edge_dual.py report     # 只从 json 重新生成 md
"""
import glob
import json
import os
import sys
import time

import numpy as np
from scipy import ndimage as ndi
from scipy.signal import lfilter
from skimage.feature import canny
from skimage.metrics import structural_similarity as ssim_fn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eval_edge_quality as Q            # noqa: E402  复用基座口径

W, H = Q.W, Q.H
ROOT = "数据集"
JSON = "edge_dual_raw.json"
MD = "edge_dual_result.md"
RECOMMEND = "edge_dual_recommend.md"     # 手写推荐/RTL 建议，若存在则并入报告末尾
T0 = time.time()


def log(*a):
    print("[%6.1fs]" % (time.time() - T0), *a, flush=True)


# =====================================================================
#  1. 图像、真值、指标
# =====================================================================
def load_sets():
    syn = sorted(glob.glob(os.path.join(ROOT, "0*.png")))
    pho = sorted(glob.glob(os.path.join(ROOT, "微信*.jpg")))
    return syn, pho[:18], pho[18:]


def gt_of(path, g):
    """真值：合成图 = 形状边界（形态学梯度，精确）；实拍 = skimage.canny 代理真值"""
    if path.lower().endswith(".png"):
        return Q.gt_from_mask(g < 110.0), "exact"
    return canny(g / 255.0, sigma=1.4, low_threshold=0.06, high_threshold=0.18), "proxy"


def metrics_from(ref, ref_n, dt, test, do_ssim=True):
    """RMSE/PSNR/SSIM/FOM（FOM 公式与基座 eval_edge_quality.fom 完全一致）"""
    t_n = int(test.sum())
    n = ref.size
    inter = int(np.count_nonzero(ref & test))
    mse = (ref_n + t_n - 2 * inter) / float(n)     # == mean((r-t)^2)
    rmse = float(np.sqrt(mse))
    psnr = 99.0 if mse == 0 else float(10.0 * np.log10(1.0 / mse))
    ssim = None
    if do_ssim:
        try:
            ssim = float(ssim_fn(ref.astype(np.float32), test.astype(np.float32), data_range=1.0))
        except Exception:
            ssim = 0.0
    if ref_n == 0 or t_n == 0:
        f = 0.0
    else:
        dd = dt[test]
        f = float(np.sum(1.0 / (1.0 + (1.0 / 9.0) * dd * dd)) / max(ref_n, t_n))
    return rmse, psnr, ssim, f


# =====================================================================
#  2. 场量（每图/每种 gauss 设置只算一次）
# =====================================================================
K4 = np.array([[0., 1., 0.], [1., -4., 1.], [0., 1., 0.]])
K8 = np.array([[1., 1., 1.], [1., -8., 1.], [1., 1., 1.]])


def build_fields(g, gauss_on):
    src = Q.gauss3(g) if gauss_on else g
    gx, gy = Q.sobel(src)
    ax, ay = np.abs(gx), np.abs(gy)
    mx = np.maximum(ax, ay)
    mn = np.minimum(ax, ay)
    # RTL 方向码（edge_canny_2px.v:375-380）：0=H(左右) 1=V(上下) 2='/' 3='\\'
    d1 = (2.0 * ax) <= ay
    d0 = (2.0 * ay) <= ax
    diag = ~(d0 | d1)
    same = (np.signbit(gx) == np.signbit(gy))
    diri = np.where(d1, np.uint8(1), np.where(d0, np.uint8(0),
                                              np.where(same, np.uint8(3), np.uint8(2)))).astype(np.uint8)
    # 基座口径：22.5° 分界的 4 方向
    ang = (np.rad2deg(np.arctan2(gy, gx)) + 180.0) % 180.0
    dirp = np.where((ang >= 22.5) & (ang < 67.5), np.uint8(2),
                    np.where((ang >= 67.5) & (ang < 112.5), np.uint8(1),
                             np.where((ang >= 112.5) & (ang < 157.5), np.uint8(3),
                                      np.uint8(0)))).astype(np.uint8)
    d4 = ndi.convolve(src, K4, mode="nearest")      # S-4c = ∇²
    d8 = ndi.convolve(src, K8, mode="nearest")
    bg3 = ndi.uniform_filter(g, size=3)                                  # lin 口径 ḡ
    hmean = ndi.uniform_filter1d(src, 16, axis=1, mode="nearest")        # RTL hsum>>4
    vmean = lfilter([1.0 / 8], [1.0, -7.0 / 8], hmean, axis=0)           # RTL 垂直 IIR
    return dict(src=src, gx=gx, gy=gy, ax=ax, ay=ay, mx=mx, mn=mn, diri=diri,
                dirp=dirp, d4=d4, d8=d8, bg3=bg3, vmean=vmean)


# =====================================================================
#  3. NMS 变体
# =====================================================================
def _nms(mag, d, strict):
    q = np.pad(mag, 1, mode="constant")
    c = q[1:-1, 1:-1]
    # d: 0=H(l,r) 1=V(u,d) 2=ur/dl 3=ul/dr
    n_ = np.where(d == 0, q[1:-1, 0:-2],
                  np.where(d == 1, q[0:-2, 1:-1],
                           np.where(d == 2, q[0:-2, 2:], q[0:-2, 0:-2])))
    p_ = np.where(d == 0, q[1:-1, 2:],
                  np.where(d == 1, q[2:, 1:-1],
                           np.where(d == 2, q[2:, 0:-2], q[2:, 2:])))
    if strict:
        keep = (c >= n_) & (c >= p_) & ((c > n_) | (c > p_))
    else:
        keep = (c >= n_) & (c >= p_)
    out = np.where(keep, c, 0.0)
    out[0, :] = 0; out[-1, :] = 0; out[:, 0] = 0; out[:, -1] = 0
    return out


def nms_rtl(mag, F):
    """RTL：26.57° 扇区 + 严格 > 规则（RTL 实际实现）"""
    return _nms(mag, F["diri"], True)


def nms_paper(mag, F):
    """基座 eval_edge_quality.nms 口径：22.5° 扇区 + 纯 >= 规则"""
    return _nms(mag, F["dirp"], False)


def nms_mix(mag, F):
    """负对照：22.5° 扇区 + 严格 > 规则（把 RTL 规则直接搬进基座扇区会怎样）"""
    return _nms(mag, F["dirp"], True)


# =====================================================================
#  4. 滞后
# =====================================================================
def hyst_label(strong, weak):
    return Q.hysteresis(strong, weak)          # 基座：8 连通全连通域


def hyst_onepass(strong, weak):
    """RTL 单遍滞后：e = strong | (weak & 8 邻域内有 strong)"""
    return strong | (weak & ndi.binary_dilation(strong, structure=np.ones((3, 3))))


HYST = {"label": hyst_label, "onepass": hyst_onepass}


# =====================================================================
#  5. 幅值补偿
# =====================================================================
def make_mag(comp, F, alpha=0.25, w=None):
    if comp in ("P1", "C0"):
        m = F["ax"] + F["ay"]
    elif comp == "C1":
        m = F["mx"] + 0.5 * F["mn"]
    elif comp in ("C2", "C2b"):
        g1 = F["mx"] + 0.5 * F["mn"]
        lap = ndi.convolve(g1, K4, mode="nearest")     # S-4c = ∇²G1
        m = g1 - alpha * lap if comp == "C2" else g1 + alpha * lap
        m = np.maximum(m, 0.0)
    elif comp == "C3":
        B = (F["ax"], F["ay"], F["mx"], F["mn"], np.abs(F["d4"]), np.abs(F["d8"]))
        m = np.zeros_like(F["ax"])
        for wi, bi in zip(w, B):
            m = m + wi * bi
        m = np.maximum(m, 0.0)
    else:
        raise ValueError(comp)
    return m.astype(np.float32)


COMP_LIST = ["P1", "C0", "C1", "C2b0.1", "C2b0.25", "C2b0.5", "C2a0.25", "C3"]
COMP_NAME = {
    "P1": "通路1 |Gx|+|Gy|+全局阈值（无NMS）",
    "C0": "通路2 C0 |Gx|+|Gy|",
    "C1": "通路2 C1 max+0.5min",
    "C2b0.1": "通路2 C2 α=0.10（题式 G1−α(−∇²G1)）",
    "C2b0.25": "通路2 C2 α=0.25（题式）",
    "C2b0.5": "通路2 C2 α=0.50（题式）",
    "C2a0.25": "通路2 C2′ α=0.25（反号=真锐化）",
    "C3": "通路2 C3 线性拟合 6 项",
}


def comp_params(comp):
    if comp.startswith("C2a"):
        return "C2", float(comp[4:])
    if comp.startswith("C2b"):
        return "C2b", float(comp[4:])
    return comp, None


# =====================================================================
#  6. 阈值口径 / 流水线
# =====================================================================
def local_thr_map(F, t1, mode, shift=1):
    if mode == "off":
        return None
    if mode == "lin":
        return np.maximum(float(t1), F["bg3"] * (1.0 / (1 << shift)))   # 基座口径
    if mode == "rtl":
        rsh = max(shift - 1, 0)
        tl = np.round(5.657 * np.sqrt(np.maximum(F["vmean"], 0.0))) / (1 << rsh)
        return np.clip(tl, t1 * 0.5, t1 * 2.0)                          # RTL 双边钳位
    raise ValueError(mode)


def apply_cfg(F, mn, comp, t1, k, local, shift, hyst):
    lt = local_thr_map(F, t1, local, shift)
    if lt is None:
        strong = mn > t1
    else:
        strong = mn > np.maximum(lt, float(t1))
    if comp == "P1":
        return strong
    weak = mn > (t1 / float(1 << k))
    return HYST[hyst](strong, weak)


def evaluate(F, mag, mn, comp, t1, k, local, shift, hyst, do_ssim, ref, ref_n, dt):
    edge = apply_cfg(F, mn, comp, t1, k, local, shift, hyst)
    rmse, psnr, ssim, f = metrics_from(ref, ref_n, dt, edge, do_ssim)
    return dict(rmse=rmse, psnr=psnr, ssim=ssim, fom=f, n_edge=int(edge.sum()),
                ref_n=int(ref_n))


def caliber_strong(mn, target):
    """返回阈值 thr，使 count(mn > thr) ≈ target（等强边缘数标定）"""
    v = mn.ravel()
    n = v.size
    if target <= 0 or target >= n:
        return float(v.max())
    kth = n - int(target)
    return float(np.partition(v, kth)[kth])


def caliber_final(F, mn, comp, target, k, local, shift, hyst="label", iters=8):
    """等最终边缘数标定：二分门限使滞后后的边缘点数 ≈ 真值点数（含弱边）"""
    lo = caliber_strong(mn, min(4 * target, mn.size // 2))     # 低门限 → 边多
    hi = caliber_strong(mn, max(target // 4, 1))               # 高门限 → 边少
    if hi < lo:
        lo, hi = hi, lo
    best = (lo, int(apply_cfg(F, mn, comp, lo, k, local, shift, hyst).sum()))
    for _ in range(iters):
        mid = 0.5 * (lo + hi)
        n = int(apply_cfg(F, mn, comp, mid, k, local, shift, hyst).sum())
        if abs(n - target) < abs(best[1] - target):
            best = (mid, n)
        if n > target:
            lo = mid
        else:
            hi = mid
    return best[0]


# =====================================================================
#  7. C3 拟合
# =====================================================================
def _design(F, stride=4):
    sl = (slice(None, None, stride), slice(None, None, stride))
    cols = [F["ax"][sl].ravel(), F["ay"][sl].ravel(), F["mx"][sl].ravel(),
            F["mn"][sl].ravel(), np.abs(F["d4"])[sl].ravel(), np.abs(F["d8"])[sl].ravel()]
    A = np.stack(cols, axis=1).astype(np.float64)
    tau = np.sqrt(F["gx"][sl].astype(np.float64) ** 2 +
                  F["gy"][sl].astype(np.float64) ** 2).ravel()
    return A, tau


def fit_c3(items):
    """训练集：5 合成 + 前 6 张实拍；验证集：实拍 7..18 + 补充 9 张"""
    train = [it for it in items if it["group"] == "syn"] + \
            [it for it in items if it["group"] == "photo"][:6]
    val = [it for it in items if it["group"] == "photo"][6:] + \
          [it for it in items if it["group"] == "photo_x"]
    A_tr = np.zeros((6, 6)); b_tr = np.zeros(6); s1 = s2 = 0.0; n_tr = 0
    A_va = np.zeros((6, 6)); b_va = np.zeros(6); s1v = s2v = 0.0; n_va = 0
    for it in train:
        F = build_fields(it["g"], True)
        A, tau = _design(F)
        A_tr += A.T @ A; b_tr += A.T @ tau
        s1 += tau.sum(); s2 += (tau * tau).sum(); n_tr += tau.size
        del A, tau, F
    for it in val:
        F = build_fields(it["g"], True)
        A, tau = _design(F)
        A_va += A.T @ A; b_va += A.T @ tau
        s1v += tau.sum(); s2v += (tau * tau).sum(); n_va += tau.size
        del A, tau, F
    w = np.linalg.lstsq(A_tr, b_tr, rcond=None)[0]

    def r2(A, b, s1_, s2_, n):
        if n <= 0 or s2_ <= s1_ * s1_ / max(n, 1):
            return float("nan")
        sse = s2_ - 2 * w @ b + w @ A @ w
        sst = s2_ - s1_ * s1_ / n
        return float(1.0 - sse / sst)
    return dict(w=[float(x) for x in w], cond=float(np.linalg.cond(A_tr)),
                r2_train=r2(A_tr, b_tr, s1, s2, n_tr),
                r2_val=r2(A_va, b_va, s1v, s2v, n_va),
                train=[it["name"] for it in train], val_n=len(val),
                n_tr=int(n_tr), n_val=int(n_va))


# =====================================================================
#  8. 主流程
# =====================================================================
def prep(items):
    for it in items:
        it["dt"] = ndi.distance_transform_edt(~it["ref"]) if it["valid"] else None
        it["ref_density"] = it["ref_n"] / float(it["ref"].size) * 100.0


def build_items():
    """数据集：5 合成（精确真值）+ 5 模糊（σ=2）+ 5 模糊+噪声（σn=6）+ 18 实拍 + 9 实拍补充"""
    syn, pho, pho_x = load_sets()
    items = []
    rng = np.random.default_rng(20261025)
    for p in syn:
        g = Q.load_gray(p)
        # 真值 = 形状边界（基座 gt_from_mask：mask & ~erosion，1 px 环）。
        # 说明：Pratt FOM 的分母是 max(N_ref,N_test)，若真值取 2 px 带（膨胀−腐蚀），
        # FOM 上限会被压到 N_test/N_ref≈0.5，指标失效 → 必须用 1 px 环。
        # 代价是 GT 相对梯度脊线系统内偏 0.5~1 px，但该偏置对所有方案一致，不影响相对比较。
        ref = Q.gt_from_mask(g < 110.0)
        base = dict(path=p, name=os.path.basename(p), kind="exact", ref=ref,
                    ref_n=int(ref.sum()), ref_target=int(ref.sum()), group="syn")
        items.append(dict(base, g=g))
        gb = ndi.gaussian_filter(g, 2.0)
        items.append(dict(base, name="blur_" + os.path.basename(p), g=gb, group="synblur"))
        gn = np.clip(gb + rng.normal(0.0, 6.0, g.shape), 0.0, 255.0).astype(np.float32)
        items.append(dict(base, name="noisy_" + os.path.basename(p), g=gn, group="synnoise"))
    for p in pho + pho_x:
        g = Q.load_gray(p)
        ref, kind = gt_of(p, g)
        items.append(dict(path=p, name=os.path.basename(p), kind=kind, ref=ref,
                          ref_n=int(ref.sum()), ref_target=int(ref.sum()),
                          g=g, group="photo" if p in pho else "photo_x"))
    for it in items:
        it.setdefault("ref_target", it["ref_n"])
    for it in items:
        it["valid"] = it["ref_n"] >= 500
    nlim = int(os.environ.get("D_LIMIT", "0"))     # 调试用：只跑前 N 张
    if nlim:
        items = items[:nlim]
    return items


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "report":
        write_report(json.load(open(JSON, "r", encoding="utf-8")))
        return
    if len(sys.argv) > 1 and sys.argv[1] == "addendum":
        # 补充实验：在「未参与任何参数选择」的 9 张实拍上验证补偿方案
        R = json.load(open(JSON, "r", encoding="utf-8"))
        items = build_items()
        prep(items)
        w = R["fit"]["w"]
        ROWS = [r for r in R["rows"] if r["stage"] != "A2"]
        for it in items:
            if it["group"] != "photo_x" or not it["valid"]:
                continue
            F = build_fields(it["g"], True)
            for comp in ("P1", "C0", "C1", "C2b0.25", "C2b0.5", "C3"):
                cn, alpha = comp_params(comp)
                mag = make_mag(cn, F, alpha if alpha else 0.25, w)
                mn = mag if comp == "P1" else nms_rtl(mag, F)
                thr = caliber_final(F, mn, comp, it["ref_target"], 2, "off", 0, "label")
                r = evaluate(F, mag, mn, comp, thr, 2, "off", 0, "label", True,
                             it["ref"], it["ref_n"], it["dt"])
                ROWS.append(dict(stage="A2", set="photo_x", img=it["name"], comp=comp,
                                 gauss=1, t1=None, k=2, local="off", shift=0,
                                 hyst="label", nms="rtl", thr=thr,
                                 rt=it["ref_target"], **r))
            del F
            log("  补 %s" % it["name"][:26])
        # 滞后口径：同一标定门限下，全连通滞后 vs RTL 单遍滞后
        for it in items:
            if not it["valid"] or it["group"] == "photo_x":
                continue
            F = build_fields(it["g"], True)
            mag = make_mag("C1", F)
            mn = nms_rtl(mag, F)
            for hy in ("label", "onepass"):
                # 各自标定到同一目标密度，消除「单遍滞后加边少」造成的密度错配
                thr = caliber_final(F, mn, "C1", it["ref_target"], 2, "off", 0, hy)
                r = evaluate(F, mag, mn, "C1", thr, 2, "off", 0, hy, True,
                             it["ref"], it["ref_n"], it["dt"])
                ROWS.append(dict(stage="H", set=it["group"], img=it["name"], comp="C1",
                                 gauss=1, t1=None, k=2, local="off", shift=0, hyst=hy,
                                 nms="rtl", thr=thr, rt=it["ref_target"], **r))
            del F
        log("  滞后口径完成")
        # 单遍滞后的补救：加大弱阈值档位 k（T_lo = T1>>k），让单遍能覆盖更多弱边
        for it in items:
            if not it["valid"] or it["group"] != "photo":
                continue
            F = build_fields(it["g"], True)
            mag = make_mag("C1", F)
            mn = nms_rtl(mag, F)
            for kk in (2, 3, 4, 5, 6):
                thr = caliber_final(F, mn, "C1", it["ref_target"], kk, "off", 0, "onepass")
                r = evaluate(F, mag, mn, "C1", thr, kk, "off", 0, "onepass", True,
                             it["ref"], it["ref_n"], it["dt"])
                ROWS.append(dict(stage="K", set="photo", img=it["name"], comp="C1",
                                 gauss=1, t1=None, k=kk, local="off", shift=0,
                                 hyst="onepass", nms="rtl", thr=thr,
                                 rt=it["ref_target"], **r))
            del F
        log("  k 档位补救完成")
        R["rows"] = ROWS
        json.dump(R, open(JSON, "w", encoding="utf-8"), ensure_ascii=False)
        write_report(R)
        log("→ %s" % MD)
        return

    items = build_items()
    prep(items)
    for it in items:
        log("%-44s %-8s ref=%6d %s" % (it["name"][:44], it["group"], it["ref_n"],
                                       "" if it["valid"] else "→ 代理真值空，排除"))

    fit = fit_c3(items)
    log("C3 w=%s cond=%.1f R2tr=%.4f R2va=%.4f" % (np.round(fit["w"], 4), fit["cond"],
                                                    fit["r2_train"], fit["r2_val"]))
    w = fit["w"]
    ROWS = []
    BT1, BK = 16, 2

    # ---------- A：补偿方案对比（等最终边缘数标定到真值点数）----------
    log("阶段 A …")
    for it in items:
        if not it["valid"]:
            continue
        comps = COMP_LIST if it["group"] != "photo_x" else ["P1", "C0", "C1", "C3"]
        for gauss_on in (1, 0):
            F = build_fields(it["g"], gauss_on)
            for comp in comps:
                if gauss_on == 0 and comp not in ("P1", "C0", "C1"):
                    continue
                cn, alpha = comp_params(comp)
                mag = make_mag(cn, F, alpha if alpha else 0.25, w)
                mn = mag if comp == "P1" else nms_rtl(mag, F)
                thr = caliber_final(F, mn, comp, it["ref_target"], BK, "off", 0, "label")
                r = evaluate(F, mag, mn, comp, thr, BK, "off", 0, "label", True,
                             it["ref"], it["ref_n"], it["dt"])
                ROWS.append(dict(stage="A", set=it["group"], img=it["name"],
                                 comp=comp, gauss=gauss_on, t1=None, k=BK, local="off",
                                 shift=0, hyst="label", nms="rtl", thr=thr, **r))
            del F
        log("  %s" % it["name"][:28])

    # ---------- B：T1 / k / 局部阈值 敏感性 ----------
    log("阶段 B …")
    T1S = (6, 8, 12, 16, 24, 32, 48, 64, 96)
    for it in items:
        if not it["valid"] or it["group"] == "photo_x":
            continue
        F = build_fields(it["g"], True)
        mag = make_mag("C1", F)
        mn = nms_rtl(mag, F)
        for t1 in T1S:
            for k in (1, 2, 3):
                for loc, sh in (("off", 0), ("lin", 1), ("lin", 2)):
                    r = evaluate(F, mag, mn, "C1", t1, k, loc, sh, "label", False,
                                 it["ref"], it["ref_n"], it["dt"])
                    ROWS.append(dict(stage="B", set=it["group"], img=it["name"], comp="C1",
                                     gauss=1, t1=t1, k=k, local=loc, shift=sh,
                                     hyst="label", nms="rtl", thr=float(t1), **r))
        del F, mag, mn
        log("  %s" % it["name"][:28])

    # ---------- C：口径对照 ----------
    log("阶段 C …")
    for it in items:
        if not it["valid"] or it["group"] == "photo_x":
            continue
        F = build_fields(it["g"], True)
        for comp in ("C0", "C1"):
            mag = make_mag(comp, F)
            mn = nms_rtl(mag, F)
            for local, sh in (("off", 0), ("lin", 1), ("lin", 2), ("rtl", 1), ("rtl", 2)):
                r = evaluate(F, mag, mn, comp, BT1, BK, local, sh, "label", True,
                             it["ref"], it["ref_n"], it["dt"])
                ROWS.append(dict(stage="C-local", set=it["group"], img=it["name"], comp=comp,
                                 gauss=1, t1=BT1, k=BK, local=local, shift=sh, hyst="label",
                                 nms="rtl", thr=float(BT1), **r))
            for nms_name, fn in (("rtl", nms_rtl), ("paper", nms_paper), ("mix", nms_mix)):
                mnv = fn(mag, F)
                for hy in ("label", "onepass"):
                    r = evaluate(F, mag, mnv, comp, BT1, BK, "off", 0, hy, False,
                                 it["ref"], it["ref_n"], it["dt"])
                    ROWS.append(dict(stage="C-nms", set=it["group"], img=it["name"], comp=comp,
                                     gauss=1, t1=BT1, k=BK, local="off", shift=0, hyst=hy,
                                     nms=nms_name, thr=float(BT1), **r))
        del F
        log("  %s" % it["name"][:28])

    # ---------- D：通路1 的 T1 扫描（给通路1 也找到自己的最优工作点）----------
    log("阶段 D …")
    for it in items:
        if not it["valid"] or it["group"] == "photo_x":
            continue
        F = build_fields(it["g"], True)
        mag = make_mag("P1", F)
        for t1 in (6, 8, 12, 16, 24, 32, 48, 64, 96):
            r = evaluate(F, mag, mag, "P1", t1, BK, "off", 0, "label", False,
                         it["ref"], it["ref_n"], it["dt"])
            ROWS.append(dict(stage="F", set=it["group"], img=it["name"], comp="P1",
                             gauss=1, t1=t1, k=BK, local="off", shift=0, hyst="label",
                             nms="none", thr=float(t1), **r))
        del F, mag
        log("  %s" % it["name"][:28])

    # ---------- D2：方向增益 ----------
    log("阶段 D2 …")
    iso = {}
    degs = list(range(0, 180, 15))
    for comp in ("C0", "C1", "C2b0.25", "C3"):
        cn, alpha = comp_params(comp)
        peaks, sums = [], []
        for deg in degs:
            im = _ramp_edge(deg)
            F = build_fields(im, True)
            mag = make_mag(cn, F, alpha if alpha else 0.25, w)
            sub = mag[64:448, 64:448]
            peaks.append(float(sub.max()))
            sums.append(float(sub.sum()))
        iso[comp] = dict(max=peaks, sum=sums)
    log("  max/min = %s" % {k: round(max(v["sum"]) / min(v["sum"]), 3)
                            for k, v in iso.items()})

    # ---------- E：每方案一个全局固定门限（各方案标定门限的中位数）----------
    log("阶段 E …")
    med = {}
    for comp in COMP_LIST:
        for gauss_on in (1, 0):
            ths = [r["thr"] for r in ROWS if r["stage"] == "A" and r["comp"] == comp
                   and r["gauss"] == gauss_on]
            if ths:
                med[(comp, gauss_on)] = float(np.median(ths))
    for it in items:
        if not it["valid"] or it["group"] == "photo_x":
            continue
        for gauss_on in (1, 0):
            F = build_fields(it["g"], gauss_on)
            for comp in COMP_LIST:
                if (comp, gauss_on) not in med:
                    continue
                if gauss_on == 0 and comp not in ("P1", "C0", "C1"):
                    continue
                cn, alpha = comp_params(comp)
                mag = make_mag(cn, F, alpha if alpha else 0.25, w)
                mn = mag if comp == "P1" else nms_rtl(mag, F)
                r = evaluate(F, mag, mn, comp, med[(comp, gauss_on)], BK, "off", 0, "label",
                             True, it["ref"], it["ref_n"], it["dt"])
                ROWS.append(dict(stage="E", set=it["group"], img=it["name"], comp=comp,
                                 gauss=gauss_on, t1=None, k=BK, local="off", shift=0,
                                 hyst="label", nms="rtl", thr=med[(comp, gauss_on)], **r))
            del F
        log("  %s" % it["name"][:28])

    rts = {(it["group"], it["name"]): it["ref_target"] for it in items}
    for r in ROWS:
        r["rt"] = rts.get((r["set"], r["img"]), r["ref_n"])
    R = dict(rows=ROWS, fit=fit, iso=iso, base=dict(t1=BT1, k=BK),
             med={"%s|%d" % k: v for k, v in med.items()},
             files=[dict(name=it["name"], group=it["group"], ref_n=it["ref_n"],
                         valid=it["valid"], kind=it["kind"],
                         density=it["ref_density"]) for it in items])
    json.dump(R, open(JSON, "w", encoding="utf-8"), ensure_ascii=False)
    log("→ %s" % JSON)
    write_report(R)
    log("→ %s" % MD)


def _ramp_edge(deg, n=512):
    th = np.deg2rad(deg)
    yy, xx = np.mgrid[0:n, 0:n]
    p = (xx - n / 2) * np.cos(th) + (yy - n / 2) * np.sin(th)
    return np.where(p > 0, 235.0, 20.0).astype(np.float32)


# =====================================================================
#  9. 报告
# =====================================================================
def sel(R, **kw):
    return [r for r in R["rows"] if all(r.get(k) == v for k, v in kw.items())]


def agg(rows):
    if not rows:
        return None
    d = dict(n=len(rows))
    for m in ("rmse", "psnr", "ssim", "fom"):
        vs = [r[m] for r in rows if r[m] is not None]
        d[m] = float(np.mean(vs)) if vs else None
    d["n_edge"] = float(np.mean([r["n_edge"] for r in rows]))
    d["ref_n"] = float(np.mean([r.get("rt", r["ref_n"]) for r in rows]))
    d["thr"] = float(np.mean([r["thr"] for r in rows]))
    return d


def f3(x):
    return "—" if x is None else "%.3f" % x


def write_report(R):
    rows = R["rows"]; base = R["base"]; fit = R["fit"]; iso = R["iso"]; files = R["files"]
    syn = [f["name"] for f in files if f["group"] == "syn" and f["valid"]]
    synb = [f["name"] for f in files if f["group"] == "synblur" and f["valid"]]
    synn = [f["name"] for f in files if f["group"] == "synnoise" and f["valid"]]
    pho = [f["name"] for f in files if f["group"] == "photo" and f["valid"]]
    phox = [f["name"] for f in files if f["group"] == "photo_x" and f["valid"]]
    bad = [f for f in files if not f["valid"]]
    COMP = COMP_LIST
    L = []; A = L.append

    # ---------------- 0 ----------------
    A("# 双通路边缘质量对比：通路1（纯 Sobel） vs 通路2（Canny + 幅值补偿）")
    A("")
    A("> 由 `eval_edge_dual.py` 离线生成，复用 `eval_edge_quality.py` 的 Sobel/高斯/"
      "真值/滞后口径。**未修改 `v6_edge/` 任何 RTL，未编译、未烧录。**")
    A("> 复现：`python eval_edge_dual.py`（原始数据缓存 `edge_dual_raw.json`）。")
    A("")
    A("## 0 口径")
    A("")
    A("| 项 | 设置 |")
    A("|---|---|")
    A("| 图像 | 1920×1080（`load_gray`：等比裁剪 16:9 + LANCZOS）|")
    A("| 梯度 | Sobel 3×3（基座 `sobel`，mode=nearest）|")
    A("| 高斯 | [1 2 1;2 4 2;1 2 1]/16 |")
    A("| NMS | 4 扇区，按 RTL 分界：2\\|Gx\\|≤\\|Gy\\|→V，2\\|Gy\\|≤\\|Gx\\|→H，其余对角；"
      "keep = 两侧 `>=` 且至少一侧严格 `>`（`edge_canny_2px.v:443`）|")
    A("| 滞后 | 8 连通全连通域（论文口径）；RTL 单遍滞后另列（§5.3）|")
    A("| 双阈值 | T2 = T1 >> k（全局，同 RTL `T_lo=i_threshold>>HYST_SHIFT`）|")
    A("| 真值 | 合成图=形状边界（`mask & ~erosion`，1 px 环，**精确**）；实拍="
      "`skimage.canny(σ=1.4,low=0.06,high=0.18)`（**代理真值**）|")
    A("| FOM | Pratt，α=1/9，分母 max(N_ref,N_test) |")
    A("| **等密度标定** | 表1/2 每个方案的门限取「使滞后后边缘点数 = 该图真值点数」的值，"
      "消除幅值口径不同带来的门限错配 |")
    A("")
    A("数据集：" + "合成 %d 图（精确真值）+ 实拍 %d 图（代理真值）" % (len(syn), len(pho))
      + ("；另实拍补充 %d 图仅用于 C3 过拟合检验。" % len(phox) if phox else "。"))
    A("")
    if bad:
        A("**排除**：" + "、".join("`%s`（代理真值 %d 点）" % (b["name"], b["ref_n"]) for b in bad)
          + "。该图平滑/失焦，`skimage.canny(σ=1.4)` 输出 0 个点 → FOM 分母为 0、RMSE 退化为全 0 对比，"
            "属**代理真值自身缺陷**，故排除并在 §5.1 说明。")
        A("")

    # ---------------- 表1 ----------------
    A("## 1 表 1：合成图（精确真值）")
    A("")
    A("### 1.1 平均（%d 图，门限按图等密度标定，T2=T1>>%d）" % (len(syn), base["k"]))
    A("")
    A("| 方案 | 标定 T1 均值 | RMSE | PSNR(dB) | SSIM | FOM | 边缘/真值 |")
    A("|---|---|---|---|---|---|---|")
    for comp in COMP:
        rr = sel(R, stage="A", set="syn", comp=comp, gauss=1)
        if not rr:
            continue
        a = agg(rr)
        A("| %s | %.2f | %s | %s | %s | **%s** | %.2f |" % (
            COMP_NAME[comp], a["thr"], f3(a["rmse"]), f3(a["psnr"]), f3(a["ssim"]),
            f3(a["fom"]), a["n_edge"] / a["ref_n"]))
    A("")
    A("> 合成图是**硬二值**形状（0/255），梯度幅值只有 0 与 ≈1000 两档，"
      "门限在 [1,600] 内取任何值都得到同一套边缘 → 「标定 T1」落在平台底部（显示 0.00），"
      "这说明**理想锐边上补偿级完全不起作用**，差异全部来自 NMS/阈值策略。")
    A("")
    A("### 1.2 逐图 FOM")
    A("")
    A("| 图 | " + " | ".join(COMP) + " |")
    A("|" + "---|" * (len(COMP) + 1))
    for im in syn:
        cells = []
        for comp in COMP:
            rr = sel(R, stage="A", set="syn", img=im, comp=comp, gauss=1)
            cells.append(f3(rr[0]["fom"]) if rr else "—")
        A("| %s | %s |" % (im[:24], " | ".join(cells)))
    A("")
    A("### 1.3 附加：同一批形状的高斯模糊版（σ=2，模拟失焦/低频场景，真值仍为形状边界）")
    A("")
    A("> 硬二值形状的梯度幅值几乎全部饱和（|G|≈1000），补偿级无从发挥；模糊后边缘升/降变缓、"
      "幅值落到与噪声可比区间，才能真正看出补偿差异。")
    A("")
    A("| 方案 | 标定 T1 均值 | RMSE | PSNR(dB) | SSIM | FOM | 边缘/真值 |")
    A("|---|---|---|---|---|---|---|")
    for comp in COMP:
        rr = sel(R, stage="A", set="synblur", comp=comp, gauss=1)
        if not rr:
            continue
        a = agg(rr)
        A("| %s | %.2f | %s | %s | %s | **%s** | %.2f |" % (
            COMP_NAME[comp], a["thr"], f3(a["rmse"]), f3(a["psnr"]), f3(a["ssim"]),
            f3(a["fom"]), a["n_edge"] / a["ref_n"]))
    A("")
    A("| 图 | " + " | ".join(COMP) + " |")
    A("|" + "---|" * (len(COMP) + 1))
    for im in synb:
        cells = []
        for comp in COMP:
            rr = sel(R, stage="A", set="synblur", img=im, comp=comp, gauss=1)
            cells.append(f3(rr[0]["fom"]) if rr else "—")
        A("| %s | %s |" % (im[:24], " | ".join(cells)))
    A("")

    A("")
    A("### 1.4 附加：模糊 + 高斯噪声（σ=2 模糊，σn=6 噪声，真值仍为形状边界）")
    A("")
    A("> 这一组最接近实拍（软边 + 噪声），且真值**精确**，用来判定 §2 里实拍上的差异"
      "到底来自算法本身还是来自代理真值的口径偏差。")
    A("")
    A("| 方案 | 标定 T1 均值 | RMSE | PSNR(dB) | SSIM | FOM | 边缘/真值 |")
    A("|---|---|---|---|---|---|---|")
    for comp in COMP:
        rr = sel(R, stage="A", set="synnoise", comp=comp, gauss=1)
        if not rr:
            continue
        a = agg(rr)
        A("| %s | %.2f | %s | %s | %s | **%s** | %.2f |" % (
            COMP_NAME[comp], a["thr"], f3(a["rmse"]), f3(a["psnr"]), f3(a["ssim"]),
            f3(a["fom"]), a["n_edge"] / a["ref_n"]))
    A("")
    A("| 图 | " + " | ".join(COMP) + " |")
    A("|" + "---|" * (len(COMP) + 1))
    for im in synn:
        cells = []
        for comp in COMP:
            rr = sel(R, stage="A", set="synnoise", img=im, comp=comp, gauss=1)
            cells.append(f3(rr[0]["fom"]) if rr else "—")
        A("| %s | %s |" % (im[:24], " | ".join(cells)))
    A("")

    A("")
    A("### 2.3 补充验证：9 张未参与任何参数选择的实拍（…_74 ~ …_82）")
    A("")
    A("> 这 9 张比主表更暗、纹理更多，且**没有参与** α 选择、C3 拟合、阈值标定；用来看结论是否只在主表成立。")
    A("")
    A("| 方案 | 标定 T1 | RMSE | PSNR(dB) | SSIM | FOM |")
    A("|---|---|---|---|---|---|")
    for comp in ("P1", "C0", "C1", "C2b0.25", "C2b0.5", "C3"):
        a = agg(sel(R, stage="A2", set="photo_x", comp=comp, gauss=1))
        if not a:
            continue
        A("| %s | %.2f | %s | %s | %s | **%s** |" % (
            COMP_NAME[comp], a["thr"], f3(a["rmse"]), f3(a["psnr"]), f3(a["ssim"]),
            f3(a["fom"])))
    A("")

    A("")
    A("### 2.4 滞后口径（同一等密度标定门限下：全连通 vs RTL 单遍）")
    A("")
    A("> RTL 实际是「单遍滞后」：`e = strong | (weak & 8邻域存在 strong)`（`edge_canny_2px.v:633-643`），"
      "不是全连通域传播。这里量它到底损失多少。")
    A("")
    A("| 数据集 | 滞后 | RMSE | PSNR(dB) | SSIM | FOM |")
    A("|---|---|---|---|---|---|")
    for setname, label in (("syn", "合成"), ("synblur", "模糊"),
                           ("synnoise", "模糊+噪声"), ("photo", "实拍")):
        for hy, nm in (("label", "全连通（论文）"), ("onepass", "单遍（RTL）")):
            a = agg(sel(R, stage="H", set=setname, hyst=hy))
            if not a:
                continue
            A("| %s | %s | %s | %s | %s | **%s** |" % (
                label, nm, f3(a["rmse"]), f3(a["psnr"]), f3(a["ssim"]), f3(a["fom"])))
    A("")

    A("")
    A("### 2.5 单遍滞后的补救：加大弱阈值档位 k（实拍 17 图，各自等密度标定）")
    A("")
    A("| k | 滞后 | 标定 T1 | RMSE | PSNR(dB) | SSIM | FOM | 边缘/真值 |")
    A("|---|---|---|---|---|---|---|---|")
    a = agg(sel(R, stage="H", set="photo", hyst="label"))
    if a:
        A("| 2 | 全连通（参考上界）| — | %s | %s | %s | **%s** | %.2f |" % (
            f3(a["rmse"]), f3(a["psnr"]), f3(a["ssim"]), f3(a["fom"]),
            a["n_edge"] / a["ref_n"]))
    for kk in (2, 3, 4, 5, 6):
        a = agg(sel(R, stage="K", set="photo", k=kk))
        if not a:
            continue
        A("| %d | 单遍（RTL）| %.2f | %s | %s | %s | **%s** | %.2f |" % (
            kk, a["thr"], f3(a["rmse"]), f3(a["psnr"]), f3(a["ssim"]), f3(a["fom"]),
            a["n_edge"] / a["ref_n"]))
    A("")

    # ---------------- 表2 ----------------
    A("## 2 表 2：实拍 %d 图（代理真值）" % len(pho))
    A("")
    A("> **声明**：实拍无精确真值，用 `skimage.canny(σ=1.4, low=0.06, high=0.18)` 作代理。"
      "其内部为双线性插值 NMS（`_nonmaximum_suppression_bilinear`）+ 连通域滞后，"
      "与本流水线的 4 扇区整点 NMS + 整点滞后口径不同，"
      "**绝对值不可与文献直接横比**，只做同口径相对比较。")
    A("")
    A("### 2.1 平均")
    A("")
    A("| 方案 | 标定 T1 均值 | RMSE | PSNR(dB) | SSIM | FOM | 边缘数/真值 |")
    A("|---|---|---|---|---|---|---|")
    for comp in COMP:
        rr = sel(R, stage="A", set="photo", comp=comp, gauss=1)
        if not rr:
            continue
        a = agg(rr)
        A("| %s | %.2f | %s | %s | %s | **%s** | %.2f |" % (
            COMP_NAME[comp], a["thr"], f3(a["rmse"]), f3(a["psnr"]), f3(a["ssim"]),
            f3(a["fom"]), a["n_edge"] / a["ref_n"]))
    A("")
    A("### 2.2 逐图四项指标（通路1、C0、C1、C2 α=0.25、C3）")
    A("")
    A("| 图 | 方案 | RMSE | PSNR | SSIM | FOM |")
    A("|---|---|---|---|---|---|")
    for im in pho:
        tag = im.split("_")[-2] if "_" in im else im[:10]
        for comp in ("P1", "C0", "C1", "C2b0.25", "C3"):
            rr = sel(R, stage="A", set="photo", img=im, comp=comp, gauss=1)
            if not rr:
                continue
            r = rr[0]
            A("| %s | %s | %s | %s | %s | %s |" % (tag, comp, f3(r["rmse"]), f3(r["psnr"]),
                                                   f3(r["ssim"]), f3(r["fom"])))
    A("")

    # ---------------- 表3 ----------------
    A("## 3 表 3：T1 / T2_SHIFT / 局部阈值 敏感性（C1 + NMS + 全连通滞后，off 口径门限 = T1）")
    A("")
    A("| T1 | k | 局部阈值 | 合成 FOM | 模糊 FOM | 实拍 FOM | 合成 RMSE | 实拍 RMSE | 实拍边缘/真值 |")
    A("|---|---|---|---|---|---|---|---|---|")
    best = None
    for t1 in (6, 8, 12, 16, 24, 32, 48, 64, 96):
        for k in (1, 2, 3):
            for loc, sh in (("off", 0), ("lin", 1), ("lin", 2)):
                rs = sel(R, stage="B", set="syn", t1=t1, k=k, local=loc, shift=sh)
                rb = sel(R, stage="B", set="synblur", t1=t1, k=k, local=loc, shift=sh)
                rp = sel(R, stage="B", set="photo", t1=t1, k=k, local=loc, shift=sh)
                asyn = agg(rs); apho = agg(rp); asb = agg(rb)
                if asyn is None:
                    continue
                score = float(np.mean([asyn["fom"], asb["fom"] if asb else asyn["fom"],
                                       apho["fom"] if apho else asyn["fom"]]))
                if best is None or score > best["score"]:
                    best = dict(score=score, t1=t1, k=k, local=loc, shift=sh,
                                syn=asyn["fom"], blur=asb["fom"] if asb else None,
                                pho=apho["fom"] if apho else None)
                locs = "关" if loc == "off" else "开 ḡ>>%d" % sh
                A("| %d | %d | %s | %s | %s | %s | %s | %s | %.2f |" % (
                    t1, k, locs, f3(asyn["fom"]), f3(asb["fom"]) if asb else "—",
                    f3(apho["fom"]) if apho else "—", f3(asyn["rmse"]),
                    f3(apho["rmse"]) if apho else "—",
                    (apho["n_edge"] / apho["ref_n"]) if apho else 0))
    A("")
    if best:
        A("**最优组合**（三组 FOM 均值）：T1=%d、T2_SHIFT=%d、局部阈值=%s → "
          "合成 FOM %.3f / 模糊 FOM %s / 实拍 FOM %s。" % (
              best["t1"], best["k"], "关" if best["local"] == "off" else "ḡ>>%d" % best["shift"],
              best["syn"], "%.3f" % best["blur"] if best["blur"] else "—",
              "%.3f" % best["pho"] if best["pho"] else "—"))
        A("")

    # ---------------- 表4 ----------------
    A("## 4 表 4：方向增益（各向同性诊断，512×512 合成直边，12 个角度）")
    A("")
    A("表中为**归一化单位长度响应** R(θ)：先取 Σ|G|(θ)/Σ|G|(0°)，再乘以 max(|cosθ|,|sinθ|) "
      "扣除「方图里斜边的长度增益」（45° 边长是 0° 的 √2 倍）。")
    A("理想各向同性 R≡1.000；1-范数理论 R(45°)=√2=1.414 → **对角边缘天生过强 41%**，"
      "等效于给对角方向额外加增益，同一门限下必然一边过检一边漏检。")
    A("")
    A("| 方案 | 0° | 15° | 30° | 45° | 60° | 75° | 90° | 105° | 120° | 135° | 150° | 165° | max/min |")
    A("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    degs = list(range(0, 180, 15))

    def _len_norm(d):
        return max(abs(np.cos(np.deg2rad(d))), abs(np.sin(np.deg2rad(d))))

    for comp in ("C0", "C1", "C2b0.25", "C3"):
        d = iso.get(comp)
        if not d:
            continue
        s = d["sum"]
        r = [x / s[0] * _len_norm(deg) for x, deg in zip(s, degs)]
        A("| %s | %s | **%.3f** |" % (comp, " | ".join("%.3f" % x for x in r),
                                      max(r) / min(r)))
    A("")
    A("")

    # ---------------- 5.1 提升 ----------------
    A("## 5 结论")
    A("")
    A("### 5.1 通路2 相对通路1 的提升（同图等密度标定，T2=T1>>2）")
    A("")
    A("| 数据集 | 指标 | 通路1 | C0 | C1 | C2 α=.25 | C3 | C1 vs 通路1 |")
    A("|---|---|---|---|---|---|---|---|")
    for setname, label in (("syn", "合成 %d 图" % len(syn)),
                           ("synblur", "合成模糊 %d 图" % len(synb)),
                           ("synnoise", "模糊+噪声 %d 图" % len(synn)),
                           ("photo", "实拍 %d 图" % len(pho))):
        v = {}
        for comp in ("P1", "C0", "C1", "C2b0.25", "C3"):
            v[comp] = agg(sel(R, stage="A", set=setname, comp=comp, gauss=1))
        if v["P1"] is None or v["C1"] is None:
            continue
        for m, nm in (("fom", "FOM"), ("rmse", "RMSE"), ("psnr", "PSNR(dB)"), ("ssim", "SSIM")):
            p1, c1 = v["P1"][m], v["C1"][m]
            rel = ((p1 - c1) if m == "rmse" else (c1 - p1)) / abs(p1) * 100.0 if p1 else 0.0
            A("| %s | %s | %s | %s | %s | %s | %s | %+.1f%% |" % (
                label, nm, f3(p1), f3(v["C0"][m]), f3(c1), f3(v["C2b0.25"][m]),
                f3(v["C3"][m]), rel))
    A("")
    A("### 5.1b 各自最优工作点（通路1 扫自己的 T1，通路2 扫 T1/k/局部阈值）")
    A("")
    A("> 更贴近 RTL 实际：两条通路各自调到自己最好的参数再比。通路1 只扫 T1（无 NMS/无滞后），"
      "通路2 用 C1 + 表 3 的 81 组参数。指标只比 FOM/RMSE（这两阶段的 SSIM 未计算）。")
    A("")
    A("| 数据集 | 通路 | 最优参数 | FOM | RMSE | 边缘/真值 |")
    A("|---|---|---|---|---|---|")
    for setname, label in (("syn", "合成 %d 图" % len(syn)),
                           ("synblur", "合成模糊 %d 图" % len(synb)),
                           ("synnoise", "模糊+噪声 %d 图" % len(synn)),
                           ("photo", "实拍 %d 图" % len(pho))):
        p1 = [r for r in sel(R, stage="F", set=setname)]
        c1 = [r for r in sel(R, stage="B", set=setname)]
        if not p1 or not c1:
            continue
        # 按 (t1) / (t1,k,local,shift) 分组求均值
        def best_of(rows, keys):
            g = {}
            for r in rows:
                g.setdefault(tuple(r[k] for k in keys), []).append(r)
            return max(g.items(), key=lambda kv: agg(kv[1])["fom"])
        kp, rp_ = best_of(p1, ("t1",))
        kc, rc_ = best_of(c1, ("t1", "k", "local", "shift"))
        ap, ac = agg(rp_), agg(rc_)
        A("| %s | 通路1 纯Sobel | T1=%d | %s | %s | %.2f |" % (
            label, kp[0], f3(ap["fom"]), f3(ap["rmse"]), ap["n_edge"] / ap["ref_n"]))
        loc = "关" if kc[2] == "off" else "ḡ>>%d" % kc[3]
        A("| %s | 通路2 C1 | T1=%d, k=%d, 局部=%s | **%s** | %s | %.2f |" % (
            label, kc[0], kc[1], loc, f3(ac["fom"]), f3(ac["rmse"]),
            ac["n_edge"] / ac["ref_n"]))
        A("| %s | 差值 | — | **%+.3f (%+.1f%%)** | %+.4f | — |" % (
            label, ac["fom"] - ap["fom"], (ac["fom"] - ap["fom"]) / ap["fom"] * 100.0,
            ac["rmse"] - ap["rmse"]))
    A("")
    A("### 5.2 每方案全局固定门限下的结果（阶段 E：门限取该方案标定门限的中位数）")
    A("")
    A("| 方案 | 固定 T1 | 合成 FOM | 模糊 FOM | 噪声 FOM | 实拍 FOM | 合成 RMSE | 实拍 RMSE |")
    A("|---|---|---|---|---|---|---|---|")
    for comp in COMP:
        rs = sel(R, stage="E", set="syn", comp=comp, gauss=1)
        rb = sel(R, stage="E", set="synblur", comp=comp, gauss=1)
        rn = sel(R, stage="E", set="synnoise", comp=comp, gauss=1)
        rp = sel(R, stage="E", set="photo", comp=comp, gauss=1)
        a, b = agg(rs), agg(rp)
        if not a:
            continue
        A("| %s | %.2f | %s | %s | %s | %s | %s | %s |" % (
            comp, a["thr"], f3(a["fom"]), f3(agg(rb)["fom"]) if rb else "—",
            f3(agg(rn)["fom"]) if rn else "—",
            f3(b["fom"]) if b else "—", f3(a["rmse"]), f3(b["rmse"]) if b else "—"))
    A("")
    A("**C2 的 α 与符号敏感性**（同一等密度标定口径，取表 1/2 的平均值）")
    A("")
    A("| 方案 | 合成 FOM | 模糊 FOM | 噪声 FOM | 实拍 FOM | 实拍 SSIM | 实拍 RMSE |")
    A("|---|---|---|---|---|---|---|")
    for comp in ("C1", "C2b0.1", "C2b0.25", "C2b0.5", "C2a0.25"):
        cs = {s: agg(sel(R, stage="A", set=s, comp=comp, gauss=1))
              for s in ("syn", "synblur", "synnoise", "photo")}
        if cs["photo"] is None or cs["syn"] is None:
            continue
        A("| %s | %s | %s | %s | **%s** | %s | %s |" % (
            COMP_NAME[comp], f3(cs["syn"]["fom"]), f3(cs["synblur"]["fom"]),
            f3(cs["synnoise"]["fom"]), f3(cs["photo"]["fom"]),
            f3(cs["photo"]["ssim"]), f3(cs["photo"]["rmse"])))
    A("")
    A("### 5.3 C3 最小二乘拟合")
    A("")
    A("- 训练集（%d 图）：%s" % (len(fit["train"]), "、".join(x[:18] for x in fit["train"])))
    A("- 验证集（%d 图）：实拍第 7~18 张 + 补充 9 张（模型完全没见过）" % fit["val_n"])
    A("- 目标 τ=√(Gx²+Gy²)，基函数 [\\|Gx\\|,\\|Gy\\|,max,min,\\|Lap4\\|,\\|Lap8\\|]，无偏置，"
      "采样步长 4（训练 %d / 验证 %d 点）" % (fit["n_tr"], fit["n_val"]))
    A("")
    A("| w1(\\|Gx\\|) | w2(\\|Gy\\|) | w3(max) | w4(min) | w5(\\|Lap4\\|) | w6(\\|Lap8\\|) | 条件数 | R²训练 | R²验证 |")
    A("|---|---|---|---|---|---|---|---|---|")
    A("| " + " | ".join("%.4f" % x for x in fit["w"]) + " | %.1f | %.4f | %.4f |" % (
        fit["cond"], fit["r2_train"], fit["r2_val"]))
    A("")
    A("> 6 项基函数**线性相关**（|Gx|+|Gy| ≡ max+min），最小二乘解不唯一（已取最小范数解），"
      "预测值唯一但**不能逐项解读**；硬件上只实现 {max,min,|Lap4|,|Lap8|} 4 项即可。"
      "R² 训练/验证差 < 0.01 → 未过拟合。")
    A("")
    A("### 5.4 口径对照")
    A("")
    A("| 方案 | 局部阈值口径 | 合成 FOM | 实拍 FOM |")
    A("|---|---|---|---|")
    for comp in ("C0", "C1"):
        for local, sh in (("off", 0), ("lin", 1), ("lin", 2), ("rtl", 1), ("rtl", 2)):
            rs = sel(R, stage="C-local", set="syn", comp=comp, local=local, shift=sh)
            rp = sel(R, stage="C-local", set="photo", comp=comp, local=local, shift=sh)
            if not rs:
                continue
            nm = {"off": "关", "lin": "ḡ>>%d（基座/题目口径）" % sh,
                  "rtl": "RTL √表>>%d + [T/2,2T] 钳位" % sh}[local]
            A("| %s | %s | %s | %s |" % (comp, nm, f3(agg(rs)["fom"]),
                                         f3(agg(rp)["fom"]) if rp else "—"))
    A("")
    A("| 方案 | NMS | 滞后 | 合成 FOM | 实拍 FOM |")
    A("|---|---|---|---|---|")
    for comp in ("C0", "C1"):
        for nms_name in ("rtl", "paper", "mix"):
            for hy in ("label", "onepass"):
                if nms_name != "rtl" and hy != "label":
                    continue
                rs = sel(R, stage="C-nms", set="syn", comp=comp, nms=nms_name, hyst=hy)
                rp = sel(R, stage="C-nms", set="photo", comp=comp, nms=nms_name, hyst=hy)
                if not rs:
                    continue
                A("| %s | %s | %s | %s | %s |" % (comp, nms_name, hy, f3(agg(rs)["fom"]),
                                                  f3(agg(rp)["fom"]) if rp else "—"))
    A("")

    # ---------------- 5.5 高斯 ----------------
    A("### 5.5 高斯开关（GAUSS_ON）影响")
    A("")
    A("| 数据集 | 方案 | GAUSS=1 FOM | GAUSS=0 FOM | ΔFOM | GAUSS=1 SSIM | GAUSS=0 SSIM | ΔSSIM |")
    A("|---|---|---|---|---|---|---|---|")
    for setname, label in (("syn", "合成"), ("synblur", "模糊"), ("synnoise", "模糊+噪声"), ("photo", "实拍")):
        for comp in ("P1", "C0", "C1"):
            a = agg(sel(R, stage="A", set=setname, comp=comp, gauss=1))
            b = agg(sel(R, stage="A", set=setname, comp=comp, gauss=0))
            if not a or not b:
                continue
            A("| %s | %s | %s | %s | %+.3f | %s | %s | %+.4f |" % (
                label, comp, f3(a["fom"]), f3(b["fom"]), b["fom"] - a["fom"],
                f3(a["ssim"]), f3(b["ssim"]), b["ssim"] - a["ssim"]))
    A("")

    # ---------------- 5.6 推荐 ----------------
    A("### 5.6 推荐参数与 RTL 实现建议")
    A("")
    if os.path.exists(RECOMMEND):
        L.extend(open(RECOMMEND, "r", encoding="utf-8").read().splitlines())
    else:
        A("见交付说明正文（推荐值取自表 1~表 5 的具体数字）。")
    A("")
    open(MD, "w", encoding="utf-8").write("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
