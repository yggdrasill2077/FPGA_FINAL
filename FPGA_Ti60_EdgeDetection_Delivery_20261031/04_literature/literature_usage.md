# 工程文献使用清单（F28）

> 说明：本清单分两部分——**第一部分是"实现里真正用到的算法原始文献"**（按模块逐条映射，写设计报告时按此引用）；
> **第二部分是工程内已归档的对标文献**（`文献对标清单.md`，90 条 A 档），用于"相关工作/同类案例"章节。
> 「核实状态」列：✅ = 经典文献，卷期页码可按通行引用；⚠️ = 本项目未核验页码/DOI，引用前需自查。

---

## 一、实现中实际用到的算法文献（按模块映射）

### 1. 边缘检测主干（`rtl/edge/edge_canny_2px.v`）

| 技术点 | 我们的实现 | 文献 | 核实状态 |
|---|---|---|---|
| Canny 五步框架（高斯→梯度→NMS→双阈值→滞后） | 2 级 3×3 高斯 → Sobel → NMS → 双阈值 + 8 连通滞后 | **Canny J. A Computational Approach to Edge Detection. IEEE TPAMI, 1986, 8(6): 679–698.** | ✅ |
| 高斯带限（σ≈1.06，3×3 二项式核级联） | `u_win_gray`/`u_win_gray2` + 系数 `[1 2 1; 2 4 2; 1 2 1]/16` | 同上（Canny 1986 §II 高斯平滑）；LoG 思想见 **Marr D, Hildreth E. Theory of Edge Detection. Proc. R. Soc. Lond. B, 1980, 207: 187–217.** | ✅ |
| Sobel 3×3 梯度算子 | `sobel_3x3.v`，Gx/Gy | **Sobel I, Feldman G. A 3×3 Isotropic Gradient Operator for Image Processing. 1968（Stanford AI Project 内部报告，常经 Duda & Hart 转引）** | ⚠️ 原始出处为未正式发表的技术报告，引用时建议用 Duda & Hart《Pattern Classification and Scene Analysis》1973 转引 |
| 幅值 1-范数 `\|Gx\|+\|Gy\|` | 赛题 B3 指定写法；`MAG_ISO_SEL=0` 时生效 | 赛题要求（非文献）；1-范数近似见 Canny 1986 | ✅ |
| 幅值欧氏近似 `max + 0.5·min`（C1） | `MAG_ISO_SEL=1` | 该近似在硬件梯度实现中常称 **hypow / α-max-β-min 范数**；系统论述见 **Ando S. Consistent Gradient Operators. IEEE TPAMI, 2000, 22(3): 252–265.** | ⚠️ 具体出处建议核对 |
| 非极大值抑制（4 方向量化） | `keep0/keep1` + 方向码 `dir0..dir3` | Canny 1986 | ✅ |
| 抛物线亚像素插值 | `num/den` → `dq0/dq1`（Q4.4） | **Canny 1986（亚像素定位）**；抛物线/二次拟合的亚像素边缘定位综述见 **Devernay F. A Non-Maxima Suppression Method for Edge Detection with Sub-Pixel Accuracy. INRIA RR-2724, 1995.** | ⚠️ Devernay 报告号需核对 |
| 双阈值 + 8 连通滞后 | `T_hi / T_lo`、`hysteresis` | Canny 1986 | ✅ |
| 亚像素抗锯齿渲染（AA） | `o_aa` 等级 2/1 → 全/半强度 | 无单一文献；属**边缘图抗锯齿渲染**工程方法（等价于 2× 超采样降采样的近似） | — |

### 2. 预处理与后处理

| 技术点 | 我们的实现 | 文献 | 核实状态 |
|---|---|---|---|
| 3×3 中值滤波（9 像素排序网络） | `median3x3_2px.v` | **Tukey J W. Exploratory Data Analysis. 1977**（中值滤波思想）；硬件排序网络见 **Astola J, Kuosmanen P. Fundamentals of Nonlinear Digital Filtering. CRC Press, 1997.** | ⚠️ 具体章节需核对 |
| 去斑（孤立点剔除） | `despeckle_2px.v`（3×3 邻域计数） | 形态学开运算/孤立点去除，见 **Rosenfeld A, Kak A C. Digital Picture Processing. 2nd ed., 1982.** | ⚠️ |
| 阈值二值化（全局参数化 + 可选局部自适应） | `EDGE_THRESHOLD`，`LOCAL_T_ON` | **Otsu N. A Threshold Selection Method from Gray-Level Histograms. IEEE Trans. SMC, 1979, 9(1): 62–66.**（自动阈值）；局部阈值对照见 Canny 1986 | ✅ Otsu |
| 颜色空间 / 白平衡 | `WB_RG/WB_GG/WB_BG`、`SWAP_RB` | **ITU-R BT.601-7. Studio encoding parameters of digital television.** | ✅ |
| 边缘细化（讨论过，未采用） | — | **Zhang T Y, Suen C Y. A Fast Parallel Algorithm for Thinning Digital Patterns. CACM, 1984, 27(3): 236–239.** | ✅ |
| 局部对比度增强（讨论过，未采用） | — | **Zuiderveld K. Contrast Limited Adaptive Histogram Equalization. Graphics Gems IV, 1994: 474–485.**；**Reza A M. Realization of the CLAHE for Real-Time Image Enhancement. J. VLSI Signal Processing, 2004, 38: 35–44.** | ✅ |

### 3. 质量评价（离线脚本 `eval_*.py`）

| 指标 | 脚本 | 文献 | 核实状态 |
|---|---|---|---|
| **FOM（Pratt 品质因数）** | `eval_edge_quality.py`、`eval_bsds.py` | **Pratt W K. Digital Image Processing. Wiley, 1978**（FOM 原始定义） | ✅ |
| **ODS / OIS / AP** | `eval_bsds.py`、`eval_bsds2.py` | **Martin D, Fowlkes C, Tal D, Malik J. A Database of Human Segmented Natural Images and its Application to Evaluating Segmentation Algorithms and Measuring Ecological Statistics. ICCV 2001.**；评测协议见 **Arbelaez P, Maire M, Fowlkes C, Malik J. Contour Detection and Hierarchical Image Segmentation. IEEE TPAMI, 2011, 33(5): 898–916.** | ✅ |
| RMSE / PSNR / SSIM | 同上 | SSIM：**Wang Z, Bovik A C, Sheikh H R, Simoncelli E P. Image Quality Assessment: From Error Visibility to Structural Similarity. IEEE TIP, 2004, 13(4): 600–612.** | ✅ |
| BSDS300 数据集 | `D:\fpga\test\BSDS300-*` | Martin 2001（数据集本体）；人工标注格式见 segbench 官方文档 | ✅ |

### 4. 学习式方法（做过可行性/离线评估，未上板）

| 方法 | 我们用在哪 | 文献 | 核实状态 |
|---|---|---|---|
| **PiDiNet（像素差分卷积）** | 离线评估"差分核 + 1×1 混合"（C1/C2/C3 实验）；结论：线性混合无收益 | **Su Z, Liu W, Yu Z, Hu D, Liao Q, Tian Q, Pietikäinen M, Liu L. Pixel Difference Networks for Efficient Edge Detection. ICCV 2021.**（arXiv:2107.02402） | ✅ |
| **HED（多尺度侧输出）** | 多尺度融合的可行性对照 | **Xie S, Tu Z. Holistically-Nested Edge Detection. ICCV 2015.** | ✅ |
| **U-Net** | 上板可行性分析（结论：1080p60 不可行） | **Ronneberger O, Fischer P, Brox T. U-Net: Convolutional Networks for Biomedical Image Segmentation. MICCAI 2015.**（arXiv:1505.04597） | ✅ |

---

## 二、工程内已归档的对标文献（`文献对标清单.md`）

### 2.1 规模与分类

| 类别 | 条目数 | 说明 |
|---|---|---|
| 一、中文期刊论文 | 约 50 条 | 知网/万方/维普/期刊官网可检索，含开放获取全文链接 |
| 二、CNKI 博硕学位论文 | 约 10 条 | |
| 三、中国发明专利 | 约 8 条 | 含 **CN114155222B**（首要对标）、CN110717852A |
| 四、英文/国际文献 | 约 10 条 | |
| 五、竞赛官方/高校公开资料 | 约 6 条 | 赛题指南、往届获奖 |
| 六、易灵思 Efinix / Ti60 官方资料 | 约 6 条 | 数据手册、开发板手册、MIPI Demo |
| **A 档合计** | **90 条** | 全部附可公开访问 URL |
| B 档待核实 | 若干 | 仅题名线索，不得直接引用 |

### 2.2 唯一取得完整 GB/T 7714 格式的条目

```
付麦霞, 邢超, 廉飞宇, 王澎. 基于FPGA的图像边缘检测器的研究和设计[J].
计算机技术与发展, 2009, (04): 196-198.
```
（注：期刊官网文献号 200904056 与 CNKI 的 WJFZ200904055 差 1 位，已在清单中如实标注）

### 2.3 首要对标文献

| 文献 | 与本工程对应点 |
|---|---|
| **CN114155222B《一种基于 FPGA 的实时边缘检测系统》** | 说明书模块构成（OV5640 + 图像获取 + 配置 + 图像处理 + AXI4 流 + 可变地址 + 视频时序 + DVI）与赛题四"采集→处理→缓存→显示"逐模块对应 |
| **CN110717852A/B《基于 FPGA 的田间视频图像实时分割系统及方法》** | 含"3×3 滤波内核窗口 + Sobel 水平/垂直 3×3 算子卷积"与"FPGA 实现 Canny 算法" |
| 《软件导刊》2024(07)《基于 FPGA 的视频实时边缘检测系统》 | 四段式框架（驱动/算法/缓存/显示），与本工程同构；有开放全文 PDF |
| 《山西电子技术》2026(02)《改进的 Canny 算法边缘检测硬件加速与实现》 | 最新同类文献，对应 Canny 分支 |

### 2.4 清单中的三个技术分歧点（可直接写进报告讨论）

| 分歧 | 清单结论 | 本工程的选择 |
|---|---|---|
| B-1 Sobel 直接阈值化 vs Canny 全流程 | 资源 vs 连续性取舍 | **两者都做**：B3 走 Sobel，A4 走 Canny（k=2 级联 + AA 渲染） |
| B-2 BRAM 行缓存 vs DDR 帧缓存 | 行缓存 10 Kbit vs 整帧 2.46 Mbit（240×） | 行缓存必做；帧缓存用于回放（A3） |
| B-3 DVP vs MIPI CSI-2 | DVP 简单、MIPI 需 D-PHY 硬核 | 本板走 **MIPI CSI-2 硬核** |

---

## 三、写报告时的引用建议

1. **算法章节**：用第一部分（Canny 1986 为主干，Otsu 1979 阈值，Pratt 1978 的 FOM，Martin 2001/Arbelaez 2011 的 BSDS 协议）
2. **相关工作章节**：用第二部分（90 条 A 档，重点 CN114155222B + 软件导刊 2024 + 山西电子技术 2026）
3. **器件/平台章节**：用第二部分第六类（Ti60 数据手册、VF 板手册）
4. **⚠️ 注意**：第一部分中标 ⚠️ 的条目（Sobel 原始报告、hypow 范数出处、Devernay 报告号、Tukey/Astola 章节）**页码/报告号需自行核对后再写入参考文献**

---

## 四、本工程中"文献 → 代码"的可追溯对照

| 文献技术点 | 落地文件 | 关键参数 |
|---|---|---|
| Canny 高斯 | `rtl/edge/edge_canny_2px.v`（`u_win_gray`, `u_win_gray2`） | 2 级 3×3，σ≈1.06 |
| Canny NMS | 同上（`keep0/keep1`, `n0/q0`） | 4 方向量化 |
| Canny 亚像素 | 同上（`num0/den0` → `dq0`） | Q4.4 抛物线 |
| Canny 双阈值滞后 | 同上（`thr_eff`, `HYST_SHIFT=4`） | T_lo = T_hi>>4 |
| Otsu/自适应阈值 | 顶层 `edge_threshold_r` + 按键 | 12 bit 幅值域，默认 56 |
| Pratt FOM | `eval_edge_quality.py::fom()` | α = 1/9 |
| BSDS ODS/OIS/AP | `eval_bsds.py`, `eval_bsds2.py` | 容差 0.0075·diag |
| SSIM | 同上（skimage `structural_similarity`） | — |
| 中值滤波 | `rtl/median3x3_2px.v` | 9 点排序 |
| 去斑 | `rtl/edge/despeckle_2px.v` | MIN_NEI=1 |
