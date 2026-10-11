/*
 * HCFR Colorimeter for macOS
 * Copyright (C) 2026 Jorge Velázquez
 *
 * This program is free software; you can redistribute it and/or modify it under the terms of
 * the GNU General Public License version 2 as published by the Free Software Foundation.
 * It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
 * the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE.
 */

/* Declarations missing in HCFR's Argyll code. MSVC accepts them implicitly; clang on arm64
   does not, and an implicit declaration would truncate pointers to 32 bits. */
#ifndef SPECTRO_COMPAT_H
#define SPECTRO_COMPAT_H
void sa_Clamp3(double out[3], double in[3]);
unsigned int rand32(unsigned int seed);
struct _icoms; struct _spydX2;
#endif
