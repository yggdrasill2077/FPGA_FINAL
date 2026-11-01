# -*- coding: utf-8 -*-
"""eval_shape_v5.py —— 在任意数据集上评估任意模型（含极性 / 对比度 / **软膝截断** 分桶）

相对 eval_shape_v4.py 的增量：
  * aux 支持 11 列（v5 数据）或 7 列 + 侧车 `_aux11_v4test.npy`（v4 数据，见 _aux11_v4test.py）
  * 新增"是否曾截断"分桶：
        tgt_frac_gt255 > 0   —— 这张图的**目标区**在 v4 硬截断点上被截过（信息真的丢了）
        frac_gt255 四分桶    —— 整图被截比例
        knee_on              —— 这张图是否触发软膝（v5 才可能为 1）
  * 逐样本落盘 knee 4 列，_tables_v5.py 可离线复算任意交叉桶

用法：
  python eval_shape_v5.py --model shape_cls_model_v4.npz --ds dataset_shapes_big5 \
                          --tag a_v4_on_big5 --out _eval_a_v4_on_big5.json
  python eval_shape_v5.py --model shape_cls_model_v5.npz --ds dataset_shapes_big5 \
                          --tag b_v5_on_big5 --out _eval_b_v5_on_big5.json
  python eval_shape_v5.py --model shape_cls_model_v5.npz --ds dataset_shapes_big4 \
                          --aux _aux11_v4test.npy --tag c_v5_on_big4 --out _eval_c_v5_on_big4.json
  python eval_shape_v5.py --model shape_cls_model_v4.npz --ds dataset_shapes_big4 \
                          --aux _aux11_v4test.npy --tag d_v4_on_big4 --out _eval_d_v4_on_big4.json
"""
import os
import sys
import json
import argparse

import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

from train_shape_cls import confusion, prf                     # noqa: E402
import train_shape_cls_v5 as T5                                 # noqa: E402

CLASSES = T5.CLASSES
NC = T5.NC
CONTRAST_EDGES = [0.0, 0.12, 0.18, 0.26, 0.36, 9.99]
CONTRAST_NAMES = ["<0.12", "0.12~0.18", "0.18~0.26", "0.26~0.36", ">=0.36"]


def _acc(mask, ok):
    return [int(mask.sum()), float(ok[mask].mean()) if mask.any() else None]


def buckets(ok, lnf, bright):
    R = {"contrast": [], "polarity": {}, "per_class_polarity": []}
    for i in range(len(CONTRAST_EDGES) - 1):
        lo, hi = CONTRAST_EDGES[i], CONTRAST_EDGES[i + 1]
        m = (lnf >= lo) & (lnf < hi)
        n, a = _acc(m, ok)
        R["contrast"].append([CONTRAST_NAMES[i], n, a] +
                             _acc(m & ~bright, ok) + _acc(m & bright, ok))
    R["polarity"] = {"dark": dict(zip(("n", "acc"), _acc(~bright, ok))),
                     "bright": dict(zip(("n", "acc"), _acc(bright, ok)))}
    return R


def knee_buckets(ok, lnf, bright, tgc, fgt):
    """'是否曾截断'分桶（tgc = 目标区 frac_gt255, fgt = 整图 frac_gt255）。"""
    R = {}
    R["tgt_clipped"] = {"dark": dict(zip(("n", "acc"), _acc(~bright & (tgc > 0), ok))),
                        "bright": dict(zip(("n", "acc"), _acc(bright & (tgc > 0), ok)))}
    R["tgt_clean"] = {"dark": dict(zip(("n", "acc"), _acc(~bright & (tgc <= 0), ok))),
                      "bright": dict(zip(("n", "acc"), _acc(bright & (tgc <= 0), ok)))}
    R["by_tgc"] = []
    for lo, hi in [(0.0, 1e-9), (1e-9, 0.05), (0.05, 0.25), (0.25, 0.6), (0.6, 9.9)]:
        m = (tgc >= lo) & (tgc < hi)
        n, a = _acc(m, ok)
        R["by_tgc"].append(["%.2f~%.2f" % (lo, hi), n, a] +
                           _acc(m & ~bright, ok) + _acc(m & bright, ok))
    R["by_fgt"] = []
    for lo, hi in [(0.0, 1e-9), (1e-9, 0.05), (0.05, 0.15), (0.15, 0.4), (0.4, 9.9)]:
        m = (fgt >= lo) & (fgt < hi)
        n, a = _acc(m, ok)
        R["by_fgt"].append(["%.2f~%.2f" % (lo, hi), n, a] +
                           _acc(m & ~bright, ok) + _acc(m & bright, ok))
    # 交叉：极性 × 曾截断
    R["polarity_x_clip"] = {
        "bright_clip": dict(zip(("n", "acc"), _acc(bright & (tgc > 0), ok))),
        "bright_noclip": dict(zip(("n", "acc"), _acc(bright & (tgc <= 0), ok))),
        "dark_clip": dict(zip(("n", "acc"), _acc(~bright & (tgc > 0), ok))),
        "dark_noclip": dict(zip(("n", "acc"), _acc(~bright & (tgc <= 0), ok))),
    }
    return R


def deep(pred, y, lnf, bright, aspect, ci, name):
    c = ci[name]
    is_c = y == c
    ok = pred[is_c] == c
    out = {"n": int(is_c.sum()), "recall": float(ok.mean()) if is_c.any() else None,
           "dark_n": int((is_c & ~bright).sum()),
           "dark_recall": float(ok[~bright[is_c]].mean()) if (is_c & ~bright).any() else None,
           "bright_n": int((is_c & bright).sum()),
           "bright_recall": float(ok[bright[is_c]].mean()) if (is_c & bright).any() else None,
           "by_contrast": [], "by_aspect": []}
    for i in range(len(CONTRAST_EDGES) - 1):
        sel = (lnf[is_c] >= CONTRAST_EDGES[i]) & (lnf[is_c] < CONTRAST_EDGES[i + 1])
        out["by_contrast"].append([CONTRAST_NAMES[i]] + _acc(sel, ok))
    if name == "rectangle":
        for lo, hi in [(1.4, 1.8), (1.8, 2.0), (2.0, 2.2), (2.2, 2.5), (2.5, 3.1)]:
            sel = (aspect[is_c] >= lo) & (aspect[is_c] < hi)
            out["by_aspect"].append(["%.1f-%.1f" % (lo, hi)] + _acc(sel, ok))
    return out


def pairs(pred, y, lnf, bright):
    out = []
    for i in range(NC):
        for j in range(NC):
            if i == j:
                continue
            m = (y == i) & (pred == j)
            if m.sum() == 0:
                continue
            out.append([CLASSES[i], CLASSES[j], int(m.sum()),
                        round(float(lnf[m].mean()), 3), round(float(bright[m].mean()), 3)])
    out.sort(key=lambda r: -r[2])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--ds", default="dataset_shapes_big5")
    ap.add_argument("--aux", default=None, help="覆盖 aux 文件名（放在 --ds 目录下或绝对路径）")
    ap.add_argument("--prep", default="dog")
    ap.add_argument("--tag", default="eval")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    T5.set_prep(a.prep)
    ds = os.path.join(ROOT, a.ds)
    p = {k: v.astype(np.float32) for k, v in np.load(os.path.join(ROOT, a.model)).items()}
    X = np.load(os.path.join(ds, "X_test.npy"))
    y = np.load(os.path.join(ds, "y_test.npy"))
    auxname = a.aux or "aux_test.npy"
    auxpath = auxname if os.path.isabs(auxname) else os.path.join(ROOT, auxname)
    if not os.path.exists(auxpath):
        auxpath = os.path.join(ds, auxname)
    A = np.load(auxpath)
    Xp = T5.prep_X(X)
    logits = np.concatenate([T5.forward(p, Xp[i:i + 250]) for i in range(0, len(X), 250)])
    pred = logits.argmax(1)
    acc = float((pred == y).mean())
    cm = confusion(pred, y)
    rows = [[str(c), int(s), float(pr), float(rc), float(f1)] for c, s, pr, rc, f1 in prf(cm)]
    macro_f1 = float(np.mean([r[4] for r in rows]))

    f = A[:, 3]
    lnf = np.abs(np.log(np.maximum(f, 1e-6)))
    bright = f > 1.0
    ok = pred == y
    ci = {c: i for i, c in enumerate(CLASSES)}
    tgt = y != ci["none"]
    B = buckets(ok[tgt], lnf[tgt], bright[tgt])
    B["n_targets"] = int(tgt.sum())
    B["per_class_polarity"] = [
        [CLASSES[i],
         int(((y == i) & ~bright).sum()),
         float(ok[(y == i) & ~bright].mean()) if ((y == i) & ~bright).any() else None,
         int(((y == i) & bright).sum()),
         float(ok[(y == i) & bright].mean()) if ((y == i) & bright).any() else None]
        for i in range(NC - 1)]
    if A.shape[1] >= 11:
        B["knee"] = knee_buckets(ok[tgt], lnf[tgt], bright[tgt],
                                 A[tgt, 10], A[tgt, 8])
    off = [(int(cm[i, j]), CLASSES[i], CLASSES[j]) for i in range(NC) for j in range(NC) if i != j]
    off.sort(reverse=True)
    res = {"tag": a.tag, "model": a.model, "ds": a.ds, "aux": os.path.basename(auxpath),
           "n": int(len(y)), "acc": acc,
           "macro_f1": macro_f1, "cm": cm.tolist(), "prf": rows, "n_err": int(len(y) - np.trace(cm)),
           "buckets": B,
           "rect": deep(pred, y, lnf, bright, A[:, 2], ci, "rectangle"),
           "square": deep(pred, y, lnf, bright, A[:, 2], ci, "square"),
           "top_confusions": off[:8],
           "pairs": pairs(pred, y, lnf, bright),
           "mean_lnf": float(lnf[y != ci["none"]].mean()),
           "bright_frac": float(bright[y != ci["none"]].mean()),
           "y": y.tolist(), "pred": pred.tolist(),
           "f": [round(float(v), 4) for v in f.tolist()],
           "aux3": [[round(float(v), 4) for v in r] for r in A[:, :3].tolist()],
           "knee": [[round(float(v), 4) for v in r] for r in A[:, 7:11].tolist()]}
    out = a.out or ("_eval_%s.json" % a.tag)
    with open(os.path.join(ROOT, out), "w", encoding="utf-8") as fp:
        json.dump(res, fp, indent=1, ensure_ascii=False)
    print("[%s] %s on %s (n=%d): acc=%.4f macroF1=%.4f err=%d  mean|lnf|=%.3f bright=%.1f%%"
          % (a.tag, a.model, a.ds, len(y), acc, macro_f1, res["n_err"],
             res["mean_lnf"], 100 * res["bright_frac"]))
    for c, s, pr, rc, f1 in rows:
        print("   %-10s n=%3d  P=%.3f R=%.3f F1=%.3f" % (c, s, pr, rc, f1))
    print("   polarity: dark %s  bright %s" % (B["polarity"]["dark"], B["polarity"]["bright"]))
    if "knee" in B:
        k = B["knee"]["polarity_x_clip"]
        print("   bright clip=%s  clean=%s" % (k["bright_clip"], k["bright_noclip"]))
        print("   dark   clip=%s  clean=%s" % (k["dark_clip"], k["dark_noclip"]))
    print("   wrote", out)


if __name__ == "__main__":
    main()
