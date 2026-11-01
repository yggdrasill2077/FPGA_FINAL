# -*- coding: utf-8 -*-
"""eval_shape_v3.py —— 在任意数据集上评估任意一个 v2/v3 模型，输出 JSON 供报告使用

为什么单独一个脚本：v3 需要三种交叉评估（严格可比），原来的 report() 只能评自己的测试集。
  1. v3 模型 × big2 测试集   -> 本轮 headline
  2. v2 模型 × big2 测试集   -> 同一批图上的严格模型对比（唯一变量 = 训练数据的长宽比策略）
  3. v3 模型 × big  测试集   -> 退化检查（老测试集里还有 aspect 1.5~1.8 的矩形）
  4. v3-48 模型 × big2 48x48 测试集 -> 分辨率实验

用法：
  python eval_shape_v3.py --model shape_cls_model_v3.npz --ds dataset_shapes_big2 --in 32 \
                          --prep dog --tag v3_on_big2 --out _eval_v3_on_big2.json
"""
import os
import sys
import json
import argparse

import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

from train_shape_cls import confusion, prf, cm_md          # noqa: E402
from train_shape_cls_v3 import forward, prep_X, CLASSES, NC  # noqa: E402


def _prf_rows(cm):
    rows = prf(cm)
    return [[str(c), int(s), float(p), float(r), float(f)] for c, s, p, r, f in rows]


def _buckets(pred, y, ang, size, aspect):
    ok = (pred == y)
    R = {}
    m = ang >= 0
    idxm = np.nonzero(m)[0]
    fold = np.mod(ang[idxm], 90.0)
    e = np.arange(0, 91, 15)
    R["angle_fold"] = [["%d-%d" % (e[i], e[i + 1]), int(((fold >= e[i]) & (fold < e[i + 1])).sum()),
                        float(ok[idxm][(fold >= e[i]) & (fold < e[i + 1])].mean())
                        if ((fold >= e[i]) & (fold < e[i + 1])).any() else None]
                       for i in range(len(e) - 1)]
    se = [0.15, 0.22, 0.30, 0.40, 0.55, 0.71]
    R["size"] = []
    for i in range(len(se) - 1):
        sel = m & (size >= se[i]) & (size < se[i + 1])
        R["size"].append(["%.0f-%.0f%%" % (se[i] * 100, se[i + 1] * 100), int(sel.sum()),
                          float(ok[sel].mean()) if sel.any() else None])
    ae = [0.90, 1.10, 1.50, 1.80, 2.00, 2.20, 2.50, 3.10]
    R["aspect_all"] = []
    for i in range(len(ae) - 1):
        sel = m & (aspect >= ae[i]) & (aspect < ae[i + 1])
        R["aspect_all"].append(["%.2f-%.2f" % (ae[i], ae[i + 1]), int(sel.sum()),
                                float(ok[sel].mean()) if sel.any() else None])
    return R


def rect_deep(pred, y, size, aspect, ci):
    """rectangle 专项：按长宽比 / 尺寸 / 两者交叉看 recall。"""
    sq, rc = ci["square"], ci["rectangle"]
    is_r = y == rc
    acc_r = (pred[is_r] == rc)
    asp_r = aspect[is_r]
    sz_r = size[is_r]
    out = {"n_rect": int(is_r.sum()), "recall": float(acc_r.mean()) if is_r.any() else None,
           "to_square": int(((pred[is_r] == sq)).sum()),
           "by_aspect": [], "by_size": [], "cross": []}
    for lo, hi in [(1.5, 1.8), (1.8, 2.0), (2.0, 2.2), (2.2, 2.5), (2.5, 3.1)]:
        sel = (asp_r >= lo) & (asp_r < hi)
        out["by_aspect"].append(["%.1f-%.1f" % (lo, hi), int(sel.sum()),
                                 float(acc_r[sel].mean()) if sel.any() else None])
    for lo, hi in [(0.15, 0.30), (0.30, 0.45), (0.45, 0.71)]:
        sel = (sz_r >= lo) & (sz_r < hi)
        out["by_size"].append(["%.0f-%.0f%%" % (lo * 100, hi * 100), int(sel.sum()),
                               float(acc_r[sel].mean()) if sel.any() else None])
    for lo, hi in [(1.8, 2.1), (2.1, 3.1)]:
        row = []
        for slo, shi in [(0.15, 0.25), (0.25, 0.35), (0.35, 0.71)]:
            sel = (asp_r >= lo) & (asp_r < hi) & (sz_r >= slo) & (sz_r < shi)
            row += [int(sel.sum()), round(float(acc_r[sel].mean()), 3) if sel.any() else None]
        out["cross"].append(["asp %.1f-%.1f" % (lo, hi)] + row)
    # 错分样本的 aspect / size 中位数（诊断误差集中在哪个方向）
    if (~acc_r).any():
        out["err_aspect_median"] = float(np.median(asp_r[~acc_r]))
        out["err_size_median"] = float(np.median(sz_r[~acc_r]))
        out["ok_aspect_median"] = float(np.median(asp_r[acc_r])) if acc_r.any() else None
        out["ok_size_median"] = float(np.median(sz_r[acc_r])) if acc_r.any() else None
    else:
        out["err_aspect_median"] = None
    return out


def square_deep(pred, y, size, aspect, ci):
    sq, rc = ci["square"], ci["rectangle"]
    is_s = y == sq
    acc_s = (pred[is_s] == sq)
    out = {"n_square": int(is_s.sum()), "recall": float(acc_s.mean()) if is_s.any() else None,
           "to_rect": int((pred[is_s] == rc).sum())}
    if (~acc_s).any():
        out["err_size_median"] = float(np.median(size[is_s][~acc_s]))
        out["err_aspect_median"] = float(np.median(aspect[is_s][~acc_s]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--ds", default="dataset_shapes_big2")
    ap.add_argument("--in", dest="inp", type=int, default=32)
    ap.add_argument("--prep", default="dog")
    ap.add_argument("--tag", default="eval")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    import train_shape_cls_v3 as T
    T.PREP2 = a.prep
    ds = os.path.join(ROOT, a.ds)
    p = {k: v.astype(np.float32) for k, v in np.load(os.path.join(ROOT, a.model)).items()}
    X = np.load(os.path.join(ds, "X_test.npy"))
    y = np.load(os.path.join(ds, "y_test.npy"))
    A = np.load(os.path.join(ds, "aux_test.npy"))
    assert X.shape[1] == a.inp, (X.shape, a.inp)
    Xp = T.prep_X(X)
    logits = np.concatenate([T.forward(p, Xp[i:i + 250]) for i in range(0, len(X), 250)])
    pred = logits.argmax(1)
    acc = float((pred == y).mean())
    cm = confusion(pred, y)
    rows = _prf_rows(cm)
    macro_f1 = float(np.mean([r[4] for r in rows]))
    ang, size, aspect = A[:, 0], A[:, 1], A[:, 2]
    ci = {c: i for i, c in enumerate(CLASSES)}
    off = [(int(cm[i, j]), CLASSES[i], CLASSES[j]) for i in range(NC) for j in range(NC) if i != j]
    off.sort(reverse=True)
    res = {"tag": a.tag, "model": a.model, "ds": a.ds, "in": a.inp, "n": int(len(y)),
           "acc": acc, "macro_f1": macro_f1, "cm": cm.tolist(), "prf": rows,
           "buckets": _buckets(pred, y, ang, size, aspect),
           "rect": rect_deep(pred, y, size, aspect, ci),
           "square": square_deep(pred, y, size, aspect, ci),
           "top_confusions": off[:6],
           "n_err": int(cm.sum() - np.trace(cm)),
           # 逐样本记录（y / pred / aux3），供离线做任意分桶与"像素差"分析
           "y": y.tolist(), "pred": pred.tolist(),
           "aux3": [[round(float(v), 4) for v in row] for row in A[:, :3].tolist()]}
    out = a.out or ("_eval_%s.json" % a.tag)
    with open(os.path.join(ROOT, out), "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, ensure_ascii=False)
    print("[%s] %s on %s (%dx%d, n=%d): acc=%.4f macroF1=%.4f err=%d" %
          (a.tag, a.model, a.ds, a.inp, a.inp, len(y), acc, macro_f1, res["n_err"]))
    for c, s, pr, rc, f1 in rows:
        print("   %-10s n=%3d  P=%.3f R=%.3f F1=%.3f" % (c, s, pr, rc, f1))
    print("   rect recall=%.3f  ->square=%d  | square recall=%.3f ->rect=%d" %
          (res["rect"]["recall"] or -1, res["rect"]["to_square"],
           res["square"]["recall"] or -1, res["square"]["to_rect"]))
    print("   rect by aspect:", res["rect"]["by_aspect"])
    print("   wrote", out)


if __name__ == "__main__":
    main()
