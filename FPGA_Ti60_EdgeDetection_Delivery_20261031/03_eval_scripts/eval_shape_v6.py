# -*- coding: utf-8 -*-
"""eval_shape_v6.py —— 48x48 (v6) vs 32x32 (v5) 四方对比 + 分桶 + 同场景配对 McNemar

三个必答臂（任务书 §3）：
  (a) v5 模型 @ 32x32，输入取自 **192 渲染图 6x6 面积平均**（dataset_shapes_big6/X32_test.npy）
  (b) v6 模型 @ 48x48，输入取自 **192 渲染图 4x4 面积平均**（dataset_shapes_big6/X48_test.npy）
  (c) v5 模型 @ 32x32，输入取自 **v5 自己的 128 渲染图 4x4 平均**（dataset_shapes_big5/X_test.npy）
      —— 与 v5 报告的 95.00% 逐样本复现（回归校验），且**行序 / 场景与 (a)(b) 完全相同**
补充臂（附带，不需要额外训练）：
  (d) v6 模型 @ 32x32（192 渲染），看 48x48 模型在 32 输入上是否退化

因为 v6 数据集的 RNG 流与 v5 逐次对齐（见 gen_shape_dataset_v6.py），
(a) (b) (c) (d) 的第 k 行都是**同一个场景**，所以 McNemar 是严格配对检验。

预处理：DoG σ 按分辨率等比缩放 —— 32x32 用 σ=1.5，48x48 用 σ=2.25（与各自训练一致）。

运行：
  python eval_shape_v6.py                       # 全部臂 + 分桶 + McNemar -> _eval_v6.json
  python eval_shape_v6.py --only a,b            # 只跑部分臂
"""
import os
import sys
import json
import argparse

import numpy as np
from scipy.stats import binomtest

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

from train_shape_cls import confusion, prf          # noqa: E402
import train_shape_cls_v6 as T6                     # noqa: E402

CLASSES = T6.CLASSES
NC = T6.NC
CI = {c: i for i, c in enumerate(CLASSES)}

DS6 = os.path.join(ROOT, "dataset_shapes_big6")
DS5 = os.path.join(ROOT, "dataset_shapes_big5")

# 任务书 §3 的分桶
SIZE_EDGES = [0.0, 0.15, 0.22, 0.30, 0.40, 0.55, 1.01]
SIZE_NAMES = ["<15%", "15-22%", "22-30%", "30-40%", "40-55%", ">=55%"]
CONTRAST_EDGES = [0.0, 0.12, 0.18, 0.26, 0.36, 9.99]
CONTRAST_NAMES = ["<0.12", "0.12~0.18", "0.18~0.26", "0.26~0.36", ">=0.36"]
ASPECT_EDGES = [1.4, 1.8, 2.0, 2.2, 2.5, 3.01]
ASPECT_NAMES = ["1.4-1.8", "1.8-2.0", "2.0-2.2", "2.2-2.5", "2.5-3.0"]

ARMS = [
    # name,                 model,                       x path,                              sig
    ("a_v5_32_on_192",      "shape_cls_model_v5.npz",    os.path.join(DS6, "X32_test.npy"),   1.5),
    ("b_v6_48_on_192",      "shape_cls_model_v6.npz",    os.path.join(DS6, "X48_test.npy"),   2.25),
    ("c_v5_32_on_128",      "shape_cls_model_v5.npz",    os.path.join(DS5, "X_test.npy"),     1.5),
    ("d_v6_32_on_192",      "shape_cls_model_v6.npz",    os.path.join(DS6, "X32_test.npy"),   1.5),
]


def _acc(mask, ok):
    return [int(mask.sum()), (float(ok[mask].mean()) if mask.any() else None)]


def predict(model_path, xpath, sig, bs=200):
    p = {k: v.astype(np.float32) for k, v in np.load(os.path.join(ROOT, model_path)).items()}
    X = np.load(xpath)
    Xp = T6.prep_at(X, sig)
    logits = np.concatenate([T6.forward(p, Xp[i:i + bs]) for i in range(0, len(Xp), bs)], 0)
    return logits.argmax(1), p


def mcnemar(ok1, ok2):
    """精确 McNemar（双侧二项）。ok1/ok2 为同一批样本的两个臂正确性。"""
    n10 = int((ok1 & ~ok2).sum())     # 1 对 2 错
    n01 = int((~ok1 & ok2).sum())     # 1 错 2 对
    n = n10 + n01
    p = 1.0 if n == 0 else float(binomtest(n10, n, 0.5).pvalue)
    return {"n10": n10, "n01": n01, "net": n10 - n01, "n": n, "p": p}


def bucket_report(pred, y, A):
    """任务书 §3 要求的分桶：size_frac / 极性 / aspect / 对比度 / square<->rect 互混。"""
    f = A[:, 3]
    size = A[:, 1]
    aspect = A[:, 2]
    lnf = np.abs(np.log(np.maximum(f, 1e-6)))
    bright = f > 1.0
    ok = pred == y
    tgt = y != CI["none"]
    R = {"n": int(len(y)), "n_target": int(tgt.sum()),
         "acc": float(ok.mean()), "acc_target": float(ok[tgt].mean())}

    # --- size_frac（只在有目标的图上分桶）---
    R["size"] = []
    for lo, hi, nm in zip(SIZE_EDGES[:-1], SIZE_EDGES[1:], SIZE_NAMES):
        m = tgt & (size >= lo) & (size < hi)
        R["size"].append([nm] + _acc(m, ok) + _acc(m & ~bright, ok) + _acc(m & bright, ok))
    m22 = tgt & (size < 0.22)
    R["small_lt22"] = dict(zip(("n", "acc"), _acc(m22, ok)))
    R["small_lt22_bright"] = dict(zip(("n", "acc"), _acc(m22 & bright, ok)))
    R["small_lt22_dark"] = dict(zip(("n", "acc"), _acc(m22 & ~bright, ok)))
    R["size_22_30"] = dict(zip(("n", "acc"), _acc(tgt & (size >= 0.22) & (size < 0.30), ok)))

    # --- 极性 ---
    R["polarity"] = {"dark": dict(zip(("n", "acc"), _acc(tgt & ~bright, ok))),
                     "bright": dict(zip(("n", "acc"), _acc(tgt & bright, ok)))}

    # --- 对比度 x 极性 ---
    R["contrast"] = []
    for lo, hi, nm in zip(CONTRAST_EDGES[:-1], CONTRAST_EDGES[1:], CONTRAST_NAMES):
        m = tgt & (lnf >= lo) & (lnf < hi)
        R["contrast"].append([nm] + _acc(m, ok) + _acc(m & ~bright, ok) + _acc(m & bright, ok))

    # --- aspect（矩形）/ 方-矩互混 ---
    is_rect = y == CI["rectangle"]
    is_sq = y == CI["square"]
    R["aspect"] = []
    for lo, hi, nm in zip(ASPECT_EDGES[:-1], ASPECT_EDGES[1:], ASPECT_NAMES):
        m = is_rect & (aspect >= lo) & (aspect < hi)
        R["aspect"].append([nm] + _acc(m, ok))
    sr = int((is_sq & (pred == CI["rectangle"])).sum())      # square -> rectangle
    rs = int((is_rect & (pred == CI["square"])).sum())       # rectangle -> square
    n_err = int(len(y) - np.trace(confusion(pred, y)))
    R["sq_rect"] = {"square2rect": sr, "rect2square": rs, "total": sr + rs,
                    "n_err": n_err,
                    "share_of_errors": (sr + rs) / max(1, n_err),
                    "n_square": int(is_sq.sum()), "n_rect": int(is_rect.sum())}
    # 只在这两类上算"它们的错误里互混占多少"
    R["sq_rect"]["sq_recall"] = float(ok[is_sq].mean())
    R["sq_rect"]["rect_recall"] = float(ok[is_rect].mean())
    # 小目标 x 方-矩
    m_small_sr = (is_sq | is_rect) & (size < 0.22)
    R["sq_rect"]["small_n"] = int(m_small_sr.sum())
    R["sq_rect"]["small_acc"] = float(ok[m_small_sr].mean()) if m_small_sr.any() else None
    return R


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None, help="逗号分隔的臂前缀，如 a,b")
    ap.add_argument("--out", default="_eval_v6.json")
    a = ap.parse_args()
    only = None if not a.only else tuple(s.strip() for s in a.only.split(","))

    y = np.load(os.path.join(DS6, "y_test.npy"))
    A = np.load(os.path.join(DS6, "aux_test.npy"))
    assert (y == np.load(os.path.join(DS5, "y_test.npy"))).all()
    res = {"n": int(len(y)), "classes": list(CLASSES), "arms": {}, "buckets": {},
           "mcnemar": [], "meta": {
               "ds6": "dataset_shapes_big6", "ds5": "dataset_shapes_big5",
               "note": "v6 与 v5 同场景（RNG 流对齐），第 k 行 = 同一场景",
               "size_edges": SIZE_EDGES, "contrast_edges": CONTRAST_EDGES,
               "aspect_edges": ASPECT_EDGES}}
    okd = {}
    for name, model, xp, sig in ARMS:
        if only and not name.startswith(only):
            continue
        if not os.path.exists(os.path.join(ROOT, model)):
            print("[skip] missing model", model, flush=True)
            continue
        X = np.load(xp)
        pred, p = predict(model, xp, sig)
        ok = pred == y
        okd[name] = ok
        cm = confusion(pred, y)
        rows = [[str(c), int(s), float(pr), float(rc), float(f1)] for c, s, pr, rc, f1 in prf(cm)]
        res["arms"][name] = {
            "model": model, "x": os.path.relpath(xp, ROOT), "in": int(X.shape[1]), "dog_sig": sig,
            "nparam": int(sum(v.size for v in p.values())),
            "mac": int(T6.mac_count(int(X.shape[1]))),
            "acc": float(ok.mean()), "macro_f1": float(np.mean([r[4] for r in rows])),
            "n_err": int(len(y) - np.trace(cm)), "cm": cm.tolist(), "prf": rows,
            "pred": pred.tolist()}
        res["buckets"][name] = bucket_report(pred, y, A)
        print("[%s] %s @ %s in=%d sigma=%.2f  acc=%.4f  macroF1=%.4f  err=%d"
              % (name, model, os.path.basename(xp), X.shape[1], sig, ok.mean(),
                 res["arms"][name]["macro_f1"], res["arms"][name]["n_err"]), flush=True)

    names = list(okd)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            r = mcnemar(okd[names[i]], okd[names[j]])
            r.update(a=names[i], b=names[j])
            res["mcnemar"].append(r)
            print("  McNemar %-16s vs %-16s  %d:%d  net=%+d  p=%.4g  %s"
                  % (names[i], names[j], r["n10"], r["n01"], r["net"], r["p"],
                     "显著" if r["p"] < 0.05 else "不显著"), flush=True)

    with open(os.path.join(ROOT, a.out), "w", encoding="utf-8") as fp:
        json.dump(res, fp, indent=1, ensure_ascii=False)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
