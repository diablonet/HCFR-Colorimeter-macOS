# Third-party code: HCFR

This folder contains the parts of **HCFR Colorimeter** used to build the macOS app. They are
copied from:

- Repository: https://github.com/arthur-liberman/hcfr-code (continuation of https://sourceforge.net/projects/hcfr/)
- Version: 3.5.4.4, commit `8ea621629aa1224ecacde49836d2675100111d0b` (2025-07-07)
- License: GNU General Public License version 2 (`LICENSE`). The ArgyllCMS files in
  `Tools/spectro` are "GNU GPL Version 2 or later" (`Tools/spectro/License2.txt`).

All original copyright notices are kept in the files.

## Contents

| Folder | What it is |
|---|---|
| `Tools/spectro/` | ArgyllCMS instrument drivers bundled with HCFR (Copyright Graeme W. Gill). Only the C sources, `License2.txt` and `Readme.txt`; Windows/Linux USB driver installers and Visual Studio project files were left out. |
| `h/` | Shared ArgyllCMS headers used by `Tools/spectro`. |
| `libnum/rand.c`, `libnum/rand.h` | Random number helper needed by the drivers. |
| `res/ColorHCFR.ico` | HCFR application icon (source of `Resources/AppIcon.icns`). |

The CCSS display corrections (`Install/color/*.ccss`) are in `../../Resources/ArgyllCMS/`.

## Modifications

Three files were modified for macOS. Each file has a notice at the top describing the change:

1. **`Tools/spectro/usbio_ox.c`** — `usb_get_paths()` indexed `p->dpaths[i][dtix_combined]`
   instead of `p->dpaths[dtix_combined][i]`. With two or more colorimeters connected the helper
   crashed and no meter was detected. Fixed the index order.
2. **`Tools/spectro/i1d3.c`** — `i1d3_diff_thread()` retried immediately after a failed
   diffuser-position query, re-taking the instrument lock in a loop and starving `read_sample()`,
   so a reading could hang forever. It now waits 500 ms before retrying.
3. **`Tools/spectro/i1d3.c`, `i1d3.h`** — added `ignore_diffpos` to the i1d3 driver. When set,
   emissive readings are not refused and display types are still listed if the diffuser sensor
   reports "ambient". The app sets it only for meter models it has not tested, after a report of
   a meter whose diffuser sensor said the diffuser was in place when it was not.

The two bugs (1 and 2) are only in the macOS code paths (the Windows build of HCFR is not affected).

The macOS build also force-includes two small headers from `../../meter/` (`spectro_compat.h`,
`inst_compat.h`) that add function declarations missing in this code, so it compiles with clang
on 64-bit macOS. No other changes were made.
