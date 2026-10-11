#!/bin/bash
# HCFR Colorimeter for macOS — Copyright (C) 2026 Jorge Velázquez — GNU GPL v2 (see LICENSE)
#
# Builds HCFR's colorimeter drivers (ArgyllCMS code in third_party/hcfr/Tools/spectro) and the
# hcfr-meter helper as a universal binary (Apple Silicon + Intel), macOS 14 or later.
ROOT="$(cd "$(dirname "$0")" && pwd)"
HCFR="$ROOT/third_party/hcfr"
SRC="$HCFR/Tools/spectro"
OUT="$ROOT/.build/meter"
mkdir -p "$OUT"
ARCHS=(-arch arm64 -arch x86_64)
MIN_MACOS="14.0"
FILES="aglob ccmx ccss cgats cgatsstd colorhug conv disptechs dtp20 dtp22 dtp41 dtp51 dtp92 ex1 hcfr hidio huey i1d3 i1disp i1pro i1pro3 i1pro3_imp i1pro_imp icoms inst insttypes kleink10 munki munki_imp numsup pars parsstd rspec rspl1 sa_conv smcube specbos spyd2 spydX spydX2 ss ss_imp usbio xdg_bds xrga xspect instappsup pollem"
CFLAGS=(-O2 -w "${ARCHS[@]}" -mmacosx-version-min=$MIN_MACOS
        -DUNIX -DSALONEINSTLIB -DENABLE_SERIAL -DENABLE_FAST_SERIAL -DENABLE_USB
        "-I$SRC" "-I$HCFR/h" -include "$ROOT/meter/spectro_compat.h")

# Rebuild everything if the architectures or the minimum macOS change
STAMP="${ARCHS[*]} $MIN_MACOS"
if [ "$(cat "$OUT/.config" 2>/dev/null)" != "$STAMP" ]; then
  rm -f "$OUT"/*.o
  echo "$STAMP" > "$OUT/.config"
fi

NEWEST="$SRC/$(ls -t "$SRC" | head -1)"
fails=0
for f in $FILES; do
  extra=(); [ $f = inst ] && extra=(-include "$ROOT/meter/inst_compat.h")
  # Rebuild when any source in the folder changed (some .c files include others, e.g. usbio_ox.c)
  [ "$OUT/$f.o" -nt "$NEWEST" ] && continue
  cc -c "${CFLAGS[@]}" "${extra[@]}" -o "$OUT/$f.o" "$SRC/$f.c" 2> "$OUT/$f.err" \
    || { fails=$((fails+1)); echo "FAIL $f"; grep "error:" "$OUT/$f.err" | head -3; }
done
cc -c "${CFLAGS[@]}" "-I$HCFR/libnum" -o "$OUT/rand.o" "$HCFR/libnum/rand.c" || fails=$((fails+1))
[ $fails -eq 0 ] || exit 1
rm -f "$OUT/libspectro.a"
# libtool (not ar) because the objects are universal
libtool -static -o "$OUT/libspectro.a" "$OUT"/*.o 2>/dev/null || exit 1
cc "${CFLAGS[@]}" -Wall -Wno-unused -o "$OUT/hcfr-meter" "$ROOT/meter/hcfr-meter.c" "$OUT/libspectro.a" \
   -framework IOKit -framework CoreFoundation -framework AppKit -framework AudioToolbox -lm || exit 1
echo "OK $OUT/hcfr-meter ($(lipo -archs "$OUT/hcfr-meter"))"
