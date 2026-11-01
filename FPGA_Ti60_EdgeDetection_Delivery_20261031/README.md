# FPGA Real-Time Edge Detection System -- Delivery Package (2026-10-31)

All file and folder names are ASCII-only, so the package can be moved between
machines without encoding issues.

## 01_docs
- TechnicalDoc_v6.docx ..... FINAL technical report (20 pages / 11 tables / 3 figures / 19 refs)
                             Filled into the official template (header/footer preserved).
                             TODO: insert real board photos (Fig.3-1/3-2) and power measurement.
- TechnicalDoc_full.md ..... full technical write-up (12 chapters, all parameters & measured data)

## 02_project_f60canny
- rtl/ ..................... all RTL sources (*.bak backups removed)
- sim/ ..................... testbenches
- bit/ ..................... final bitstream + place/timing/hier_util reports + programming log
                             SHA256 = 18B58A493F061DEEF2450F9D76ACE75BE7464C029722F04923BA9251A42A0494
- debug_top.v .............. REQUIRED by ti60f225_oob.xml (missing it causes
                             "project contains some invalid configuration")
- ti60f225_oob.xml / .peri.xml / .sdc ... Efinity project and constraints

Verified: 81 design files referenced by the XML, 0 missing.

### Current firmware status
| Item | Value |
|---|---|
| XLR | 58,804 / 60,800 (96.72%) |
| RAM10 | 221 / 256 (86.33%)  WARNING: above the 85% limit |
| DSP | 73 / 160 (45.62%) |
| Worst slack | +0.261 ns |

### Keys
- KEY0 / KEY3 : threshold +64 / -64 (floor = 24)
- KEY0 + KEY3 held 0.8 s : freeze / unfreeze
- KEY1 + KEY2 held 0.8 s : switch Canny <-> direct Sobel
                           (in Sobel mode the shape boxes are hidden)
- while frozen: KEY2 = step one frame, KEY1 = auto replay

## 03_eval_scripts
Offline evaluation scripts (FOM / ODS / OIS / AP / connectivity / sub-pixel AA / multi-scale)
plus three comparison images.

## 04_literature
- literature_benchmark_90A.md ... 90 A-tier benchmark references
- literature_usage.md ........... algorithm references actually used + "reference -> code" map

## Build / program
1. Open 02_project_f60canny/ti60f225_oob.xml with Efinity 2026.1 (Titanium device support required).
2. efx_run.bat ti60f225_oob.xml -f compile --output_dir outflow --work_dir work
3. Before programming check: RAM <= 85%, slack > 0.
4. efx_run.bat ti60f225_oob.xml -f program --pgm_opts mode=jtag --output_dir outflow --work_dir work
   If it reports "list index out of range", the JTAG link dropped -- re-plug the USB cable.

## Notes
- Keep the extracted path ASCII and space-free (e.g. D:\work\fpga\).
- The .mem files used by  are inside rtl/edge/ (letter_*.mem, polar_trig.mem, shape_templates.mem).
