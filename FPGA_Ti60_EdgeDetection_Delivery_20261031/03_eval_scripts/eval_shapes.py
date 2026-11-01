# -*- coding: utf-8 -*-
"""
形状识别离线评测（与 RTL 位精确等价）
  用法: python eval_shapes.py [图片目录] [--th-mode 0|1]
  输出: 控制台表 + eval_result.csv + 标注图到 数据集/eval_out/
说明: 图像统一拉伸到 1920x1080（模拟相机整幅视场），灰度后走与 shape_recog.v 相同的判定链。
"""
import os
import sys
import glob
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
FONT = "C:/Windows/Fonts/msyh.ttc"

# ---- 与 RTL 一致的可调参数（改这里就等于改 localparam）----
P = dict(TH_MODE=0, THRESH=128, TH_DELTA=24, BBX_MAX=1400, BBY_MAX=820,
         A_MIN=150, A_MAX=65530, FILL_MIN=297, K_CIRC=10616, K_RECT=125112)


def load_gray(path):
    im = Image.open(path).convert("L")
    if im.size != (W, H):
        im = im.resize((W, H), Image.LANCZOS)
    return np.array(im, dtype=np.uint8)


def rtl_eval(g):
    """返回 dict：mu/pol/A/bbox/fill/cg/fmom/cls/reason"""
    gg = g.astype(np.int64)
    mu = int(gg.sum() // (W * H))                 # RTL: Σg>>21
    pol = 1 if mu > 128 else 0                    # 1 = 取暗目标

    if P["TH_MODE"] == 0:
        fg = (gg <= P["THRESH"]) if pol else (gg > P["THRESH"])
    else:
        fg = (gg < mu - P["TH_DELTA"]) if pol else (gg > mu + P["TH_DELTA"])

    ys, xs = np.mgrid[0:H, 0:W]
    smp = (ys % 4 == 0) & (xs % 4 == 0)
    s = fg & smp
    a = int(s.sum())
    if a == 0:
        return dict(mu=mu, pol=pol, a=0, cls=0, reason="无前景")

    y = ys[s].astype(np.int64)
    x = xs[s].astype(np.int64)
    bx0, bx1 = int(x.min()), int(x.max())
    by0, by1 = int(y.min()), int(y.max())
    bw, bh = bx1 - bx0 + 1, by1 - by0 + 1

    rej = []
    touch = (bx0 == 0) or (by0 == 0) or (bx1 >= W - 1) or (by1 >= H - 1)
    if touch:
        rej.append("触边")
    if (bw > P["BBX_MAX"]) or (bh > P["BBY_MAX"]):
        rej.append(f"bbox{bw}x{bh}过大")
    if a < P["A_MIN"]:
        rej.append(f"面积{a}小")
    fill = 16.0 * a / (bw * bh)
    if (16 * a * 1024) < P["FILL_MIN"] * bw * bh:
        rej.append(f"fill{fill:.2f}低")

    sx, sy = int(x.sum()), int(y.sum())
    sxx, syy, sxy = int((x * x).sum()), int((y * y).sum()), int((x * y).sum())
    a2 = a * a
    Pnum = a * sxx - sx * sx
    Qnum = a * syy - sy * sy
    Rnum = a * sxy - sx * sy
    m20 = (Pnum << 12) // a2
    m02 = (Qnum << 12) // a2
    m11 = (abs(Rnum) << 12) // a2
    circ = (a * P["K_CIRC"] >= m20 + m02)
    lq = max((m20 >> 4) * (m02 >> 4) - (m11 >> 4) ** 2, 0)
    rect = (lq <= P["K_RECT"] * a2)
    tr = (m20 + m02) / 4096.0
    cg = (16.0 * a) / (math.pi * tr) if tr > 0 else 0.0
    fmom = (16.0 * a) / (12.0 * math.sqrt(max(lq, 1) / 65536.0))

    if a > P["A_MAX"]:
        rej.append("面积饱和")
    ok = not rej
    cls = 0 if not ok else (1 if circ else (2 if rect else 0))
    return dict(mu=mu, pol=pol, a=a, bw=bw, bh=bh, bx0=bx0, bx1=bx1, by0=by0, by1=by1,
                fill=fill, cg=cg, fmom=fmom, circ=bool(circ), rect=bool(rect),
                cls=cls, reason=",".join(rej) if rej else "")


def annotate(path, g, r, outdir):
    im = Image.open(path).convert("RGB")
    if im.size != (W, H):
        im = im.resize((W, H), Image.LANCZOS)
    d = ImageDraw.Draw(im)
    try:
        f = ImageFont.truetype(FONT, 30)
    except Exception:
        f = ImageFont.load_default()
    ok = r["cls"] != 0
    col = (0, 220, 0) if ok else (255, 60, 60)
    if r.get("a", 0):
        x0, x1 = r["bx0"] // 2, r["bx1"] // 2      # 左半屏 2:1
        d.rectangle([x0, r["by0"], x1, r["by1"]], outline=col, width=3)
    name = {0: "未知", 1: "圆", 2: "矩形"}[r["cls"]]
    txt = f"{name}"
    if r.get("a", 0):
        txt += f"  A={r['a']} bbox={r['bw']}x{r['bh']} fill={r['fill']:.2f} cg={r['cg']:.2f}"
    if r["reason"]:
        txt += f"  [{r['reason']}]"
    d.text((20, H - 60), txt, fill=col, font=f)
    d.text((20, 20), f"mu={r['mu']} pol={r['pol']}", fill=col, font=f)
    out = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0] + "_eval.png")
    im.save(out)
    return out


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "数据集"
    if "--th-mode" in sys.argv:
        P["TH_MODE"] = int(sys.argv[sys.argv.index("--th-mode") + 1])
    files = []
    for ext in ("*.png", "*.jpg", "*.jpeg", "*.bmp", "*.PNG", "*.JPG"):
        files += glob.glob(os.path.join(root, ext))
    files = sorted(set(files))
    if not files:
        print(f"[!] {root} 里没有图片（支持 png/jpg/bmp）")
        return
    outdir = os.path.join(root, "eval_out")
    os.makedirs(outdir, exist_ok=True)
    rows = []
    print("=" * 118)
    print(f"{'文件':28s} {'mu':>4s} {'pol':>3s} {'A':>7s} {'bbox':>11s} {'fill':>5s} {'c_g':>5s} {'f_mom':>5s}  判定   原因")
    print("=" * 118)
    for p in files:
        g = load_gray(p)
        r = rtl_eval(g)
        annotate(p, g, r, outdir)
        cls = {0: "未知", 1: "圆  ", 2: "矩形"}[r["cls"]]
        bbox = f"{r['bw']}x{r['bh']}" if r.get("a") else "-"
        print(f"{os.path.basename(p)[:28]:28s} {r['mu']:4d} {r['pol']:3d} "
              f"{r.get('a',0):7d} {bbox:>11s} {r.get('fill',0):5.2f} "
              f"{r.get('cg',0):5.2f} {r.get('fmom',0):5.2f}  {cls}  {r['reason']}")
        rows.append(r | {"file": os.path.basename(p)})
    print("-" * 118)
    n = len(rows)
    from collections import Counter
    c = Counter(r["cls"] for r in rows)
    print(f"共 {n} 张 ｜ 圆 {c[1]} ｜ 矩形 {c[2]} ｜ 未知 {c[0]}")
    # CSV
    csv = os.path.join(root, "eval_result.csv")
    keys = ["file", "mu", "pol", "a", "bw", "bh", "fill", "cg", "fmom", "cls", "reason"]
    with open(csv, "w", encoding="utf-8-sig") as fh:
        fh.write(",".join(keys) + "\n")
        for r in rows:
            fh.write(",".join(str(round(r.get(k, 0), 4)) if isinstance(r.get(k, 0), float)
                              else str(r.get(k, 0)) for k in keys) + "\n")
    print(f"标注图 → {outdir}")
    print(f"结果表 → {csv}")


if __name__ == "__main__":
    main()
