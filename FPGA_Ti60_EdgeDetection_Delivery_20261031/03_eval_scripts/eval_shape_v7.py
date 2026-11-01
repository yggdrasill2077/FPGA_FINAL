# -*- coding: utf-8 -*-
"""eval_shape_v7.py —— v7（32x32, 192 渲染 + 6x6 平均）评估：分桶 + 同输入对照 + McNemar

四个臂（测试集 1000 张，第 k 行 = 同一个场景）：
  (a) **v7** @ 32x32（v7 数据，6x6 平均）                <- 主结果
  (b) **v5** @ 32x32（**同一批 32x32 输入**）            <- 数据一致性校验（应 95.60%）
  (c) v5 @ 32x32（v5 自己的 128 渲染 4x4 平均）          <- v5 报告的 95.00% 复现
  (d) v6 @ 48x48（v6 数据）                              <- 上轮结论复现（94.70%）
  (e) v7 @ 32x32，输入按 **uint8 取整**（RTL 前端的真实格式）  <- 部署口径

分桶（任务书要求）：size_frac 小目标(<22%) / 亮暗极性 / |ln f| 对比度 / aspect / square<->rect。

运行：
  python eval_shape_v7.py                 # 全部臂 -> _eval_v7.json
  python eval_shape_v7.py --only a,b
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
import train_shape_cls_v7 as T7                     # 先 import v7（它设 DS/MODEL env 并 import v4）
import train_shape_cls_v4 as _v4                    # noqa: E402

CLASSES = T7.CLASSES
NC = T7.NC
CI = {c: i for i, c in enumerate(CLASSES)}

DS7 = os.path.join(ROOT, "dataset_shapes_big7")
DS6 = os.path.join(ROOT, "dataset_shapes_big6")
DS5 = os.path.join(ROOT, "dataset_shapes_big5")

SIZE_EDGES = [0.0, 0.15, 0.22, 0.30, 0.40, 0.55, 1.01]
SIZE_NAMES = ["<15%", "15-22%", "22-30%", "30-40%", "40-55%", ">=55%"]
CONTRAST_EDGES = [0.0, 0.12, 0.18, 0.26, 0.36, 9.99]
CONTRAST_NAMES = ["<0.12", "0.12~0.18", "0.18~0.26", "0.26~0.36", ">=0.36"]
ASPECT_EDGES = [1.4, 1.8, 2.0, 2.2, 2.5, 3.01]
ASPECT_NAMES = ["1.4-1.8", "1.8-2.0", "2.0-2.2", "2.2-2.5", "2.5-3.0"]

ARMS = [
    ("a_v7_32", "shape_cls_model_v7.npz", os.path.join(DS7, "X_test.npy"), 1.5, False),
    ("b_v5_32_sameX", "shape_cls_model_v5.npz", os.path.join(DS7, "X_test.npy"), 1.5, False),
    ("c_v5_32_on128", "shape_cls_model_v5.npz", os.path.join(DS5, "X_test.npy"), 1.5, False),
    ("d_v6_48_on192", "shape_cls_model_v6.npz", os.path.join(DS6, "X48_test.npy"), 2.25, False),
    ("e_v7_32_uint8", "shape_cls_model_v7.npz", os.path.join(DS7, "X_test.npy"), 1.5, True),
]


def _acc(mask, ok):
    return [int(mask.sum()), (float(ok[mask].mean()) if mask.any() else None)]


def predict(model_path, X, sig, quant_in=False, bs=200):
    p = {k: v.astype(np.float32) for k, v in np.load(os.path.join(ROOT, model_path)).items()}
    if quant_in:
        X = np.rint(X * 255.0) / 255.0
    Xp = T7.prep_at(X, sig)
    logits = np.concatenate([_v4.forward(p, Xp[i:i + bs]) for i in range(0, len(Xp), bs)], 0)
    return logits.argmax(1), p, logits


def mcnemar(ok1, ok2):
    n10 = int((ok1 & ~ok2).sum())
    n01 = int((~ok1 & ok2).sum())
    n = n10 + n01
    p = 1.0 if n == 0 else float(binomtest(n10, n, 0.5).pvalue)
    return {"n10": n10, "n01": n01, "net": n10 - n01, "n": n, "p": p}


def bucket_report(pred, y, A):
    f, size, aspect = A[:, 3], A[:, 1], A[:, 2]
    lnf = np.abs(np.log(np.maximum(f, 1e-6)))
    bright = f > 1.0
    ok = pred == y
    tgt = y != CI["none"]
    R = {"n": int(len(y)), "n_target": int(tgt.sum()),
         "acc": float(ok.mean()), "acc_target": float(ok[tgt].mean())}
    R["size"] = []
    for lo, hi, nm in zip(SIZE_EDGES[:-1], SIZE_EDGES[1:], SIZE_NAMES):
        m = tgt & (size >= lo) & (size < hi)
        R["size"].append([nm] + _acc(m, ok) + _acc(m & ~bright, ok) + _acc(m & bright, ok))
    m22 = tgt & (size < 0.22)
    R["small_lt22"] = dict(zip(("n", "acc"), _acc(m22, ok)))
    R["small_lt22_bright"] = dict(zip(("n", "acc"), _acc(m22 & bright, ok)))
    R["small_lt22_dark"] = dict(zip(("n", "acc"), _acc(m22 & ~bright, ok)))
    R["polarity"] = {"dark": dict(zip(("n", "acc"), _acc(tgt & ~bright, ok))),
                     "bright": dict(zip(("n", "acc"), _acc(tgt & bright, ok)))}
    R["contrast"] = []
    for lo, hi, nm in zip(CONTRAST_EDGES[:-1], CONTRAST_EDGES[1:], CONTRAST_NAMES):
        m = tgt & (lnf >= lo) & (lnf < hi)
        R["contrast"].append([nm] + _acc(m, ok) + _acc(m & ~bright, ok) + _acc(m & bright, ok))
    is_rect = y == CI["rectangle"]
    is_sq = y == CI["square"]
    R["aspect"] = []
    for lo, hi, nm in zip(ASPECT_EDGES[:-1], ASPECT_EDGES[1:], ASPECT_NAMES):
        m = is_rect & (aspect >= lo) & (aspect < hi)
        R["aspect"].append([nm] + _acc(m, ok))
    sr = int((is_sq & (pred == CI["rectangle"])).sum())
    rs = int((is_rect & (pred == CI["square"])).sum())
    n_err = int(len(y) - np.trace(confusion(pred, y)))
    R["sq_rect"] = {"square2rect": sr, "rect2square": rs, "total": sr + rs, "n_err": n_err,
                    "share_of_errors": (sr + rs) / max(1, n_err),
                    "n_square": int(is_sq.sum()), "n_rect": int(is_rect.sum()),
                    "sq_recall": float(ok[is_sq].mean()),
                    "rect_recall": float(ok[is_rect].mean())}
    m_small_sr = (is_sq | is_rect) & (size < 0.22)
    R["sq_rect"]["small_n"] = int(m_small_sr.sum())
    R["sq_rect"]["small_acc"] = float(ok[m_small_sr].mean()) if m_small_sr.any() else None
    return R


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None)
    ap.add_argument("--out", default="_eval_v7.json")
    a = ap.parse_args()
    only = None if not a.only else tuple(s.strip() for s in a.only.split(","))

    y = np.load(os.path.join(DS7, "y_test.npy"))
    A = np.load(os.path.join(DS7, "aux_test.npy"))
    assert (y == np.load(os.path.join(DS5, "y_test.npy"))).all()
    res = {"n": int(len(y)), "classes": list(CLASSES), "arms": {}, "buckets": {},
           "mcnemar": [], "meta": {
               "ds7": "dataset_shapes_big7 (192 渲染 -> 6x6 平均 -> 32)",
               "note": "v7 与 v5/v6 同场景（RNG 流对齐，v7 X 与 big6/X32 逐位相同）",
               "size_edges": SIZE_EDGES, "contrast_edges": CONTRAST_EDGES,
               "aspect_edges": ASPECT_EDGES}}
    okd = {}
    for name, model, xp, sig, qin in ARMS:
        if only and not name.startswith(only):
            continue
        if not os.path.exists(os.path.join(ROOT, model)):
            print("[skip] missing model", model, flush=True)
            continue
        X = np.load(xp)
        pred, p, logits = predict(model, X, sig, qin)
        ok = pred == y
        okd[name] = ok
        cm = confusion(pred, y)
        rows = [[str(c), int(s), float(pr), float(rc), float(f1)] for c, s, pr, rc, f1 in prf(cm)]
        res["arms"][name] = {
            "model": model, "x": os.path.relpath(xp, ROOT), "in": int(X.shape[1]),
            "dog_sig": sig, "quant_in_uint8": bool(qin),
            "nparam": int(sum(v.size for v in p.values())),
            "mac": int(_v4.mac_count(int(X.shape[1]))),
            "acc": float(ok.mean()), "macro_f1": float(np.mean([r[4] for r in rows])),
            "n_err": int(len(y) - np.trace(cm)), "cm": cm.tolist(), "prf": rows,
            "pred": pred.tolist()}
        res["buckets"][name] = bucket_report(pred, y, A)
        print("[%-16s] %-22s in=%d sig=%.2f  acc=%.4f  macroF1=%.4f  err=%d"
              % (name, model, X.shape[1], sig, ok.mean(),
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

    # ---- 关键分桶打印 ----
    for name in okd:
        B = res["buckets"][name]
        sm = B["small_lt22"]
        print("  %-16s small(<22%%) %.3f (n=%d)  dark %.3f  bright %.3f  sq %.3f  rect %.3f"
              % (name, sm["acc"] or -1, sm["n"], B["polarity"]["dark"]["acc"] or -1,
                 B["polarity"]["bright"]["acc"] or -1, B["sq_rect"]["sq_recall"],
                 B["sq_rect"]["rect_recall"]), flush=True)

    with open(os.path.join(ROOT, a.out), "w", encoding="utf-8") as fp:
        json.dump(res, fp, indent=1, ensure_ascii=False)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
