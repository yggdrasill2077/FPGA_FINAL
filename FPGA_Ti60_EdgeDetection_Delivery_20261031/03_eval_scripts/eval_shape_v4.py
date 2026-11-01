# -*- coding: utf-8 -*-
"""eval_shape_v4.py —— 在任意数据集上评估任意模型，并输出**含对比度 / 极性分桶**的 JSON

v3 的 eval 只存了 aux 的前 3 列（angle/size/aspect），f（对比度）没存，导致"亮/暗极性"
没法从 JSON 复算。v4 的核心指标恰恰是极性，所以这里把 f 一并落盘，并直接算好：
  * |ln f| 四档分桶准确率（<0.12 / 0.12~0.18 / 0.18~0.26 / >=0.26，外加 0.26~0.36 / >=0.36）
  * 亮目标（f>1）/ 暗目标（f<1）准确率，以及每类各自的极性准确率
  * rectangle / square recall（整体 + 按极性 + 按 |ln f| 档 + 按 aspect）
  * 全部非对角混淆对（含该对的平均 |ln f| 与亮目标占比）—— 直接对应 v3 的 12/15 结论

用法：
  python eval_shape_v4.py --model shape_cls_model_v2.npz --ds dataset_shapes_big4 --tag v2_on_big4 \
                          --out _eval_v2_on_big4.json
"""
import os
import sys
import json
import argparse

import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

from train_shape_cls import confusion, prf                     # noqa: E402
from train_shape_cls_v4 import forward, prep_X, CLASSES, NC    # noqa: E402

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
    ap.add_argument("--ds", default="dataset_shapes_big4")
    ap.add_argument("--prep", default="dog")
    ap.add_argument("--tag", default="eval")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    import train_shape_cls_v4 as T
    T.PREP2 = a.prep
    ds = os.path.join(ROOT, a.ds)
    p = {k: v.astype(np.float32) for k, v in np.load(os.path.join(ROOT, a.model)).items()}
    X = np.load(os.path.join(ds, "X_test.npy"))
    y = np.load(os.path.join(ds, "y_test.npy"))
    A = np.load(os.path.join(ds, "aux_test.npy"))
    Xp = T.prep_X(X)
    logits = np.concatenate([T.forward(p, Xp[i:i + 250]) for i in range(0, len(X), 250)])
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
    # none 类没有目标（f 恒为 1.0），对比度/极性分桶只在 5 个"有目标"类上统计
    # —— 与 v3 报告的口径一致（860 张目标样本），否则 140 张 none 会灌进 <0.12 档
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
    off = [(int(cm[i, j]), CLASSES[i], CLASSES[j]) for i in range(NC) for j in range(NC) if i != j]
    off.sort(reverse=True)
    res = {"tag": a.tag, "model": a.model, "ds": a.ds, "n": int(len(y)), "acc": acc,
           "macro_f1": macro_f1, "cm": cm.tolist(), "prf": rows, "n_err": int(len(y) - np.trace(cm)),
           "buckets": B,
           "rect": deep(pred, y, lnf, bright, A[:, 2], ci, "rectangle"),
           "square": deep(pred, y, lnf, bright, A[:, 2], ci, "square"),
           "top_confusions": off[:8],
           "pairs": pairs(pred, y, lnf, bright),
           "mean_lnf": float(lnf[y != ci["none"]].mean()),
           "bright_frac": float(bright[y != ci["none"]].mean()),
           # 逐样本（含 f），供离线复算任意分桶
           "y": y.tolist(), "pred": pred.tolist(),
           "f": [round(float(v), 4) for v in f.tolist()],
           "aux3": [[round(float(v), 4) for v in r] for r in A[:, :3].tolist()]}
    out = a.out or ("_eval_%s.json" % a.tag)
    with open(os.path.join(ROOT, out), "w", encoding="utf-8") as fp:
        json.dump(res, fp, indent=1, ensure_ascii=False)
    print("[%s] %s on %s (n=%d): acc=%.4f macroF1=%.4f err=%d  mean|lnf|=%.3f bright=%.1f%%" %
          (a.tag, a.model, a.ds, len(y), acc, macro_f1, res["n_err"],
           res["mean_lnf"], 100 * res["bright_frac"]))
    for c, s, pr, rc, f1 in rows:
        print("   %-10s n=%3d  P=%.3f R=%.3f F1=%.3f" % (c, s, pr, rc, f1))
    print("   contrast:", [(n, c, None if v is None else round(v, 3)) for n, c, v, _, _, _, _ in
                           B["contrast"]])
    print("   polarity: dark %s  bright %s" % (B["polarity"]["dark"], B["polarity"]["bright"]))
    print("   wrote", out)


if __name__ == "__main__":
    main()
