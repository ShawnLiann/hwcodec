#!/bin/bash
# Encode-side zero-copy verification. Runs on a macOS runner (needs Xcode CLT, not vcpkg).
#
#   scripts/verify-encode-zerocopy.sh [path-to-encode_synth3.m]
#
# Set LIBYUV_PREFIX to a directory holding include/libyuv.h and lib/libyuv.a to use a specific
# libyuv build (CI builds one there); otherwise the script looks in VCPKG_ROOT, Homebrew and
# the old bench tree.
#
# Guards, in order:
#   1. the wrapper compiles and encodes: keyframe present, non-zero bitstream, every frame delivered
#   2. submit CPU at 4K stays below 2 ms/frame (a regression here means the pixel buffer path became
#      a copy again)
#   3. with libyuv available (vcpkg or brew), the BGRA-direct stream must stay within 1.5 dB of the
#      libyuv path. This is the check that catches a missing BT.601 attachment -- it fails hard at
#      ~27.6 dB when the tag is absent.
set -uo pipefail
# STRICT=1 (default): assert an IDR and require the direct path to stay within 1.5 dB of the
# libyuv path. STRICT=0 is for hosted macOS runners, which have no AppleM2ScalerCSCDriver:
# there HEVC reports keys=0 while still delivering a decodable stream, and the BGRA path lands
# ~3 dB from the libyuv path (measured 48.17 vs 51.27) instead of ~0.1 dB on real hardware.
# In that mode require a bitstream and a 40 dB absolute floor, which still catches a missing
# BT.601 tag (~27.6 dB on any machine).
STRICT=${STRICT:-1}
# Resolve the harness before cd: a relative path would stop matching once we change directory,
# and the PSNR guard would then skip silently instead of failing.
AB_ARG=${1:-}
if [ -n "$AB_ARG" ] && [ -f "$AB_ARG" ]; then
  AB_ARG="$(cd "$(dirname "$AB_ARG")" && pwd)/$(basename "$AB_ARG")"
fi
cd "$(dirname "$0")/.."
SRC=src/ffmpeg_ram
WORK=$(mktemp -d)
fail=0

echo "== 1. build the wrapper and its smoke test =="
clang++ -x objective-c++ -O2 -fobjc-arc -c "$SRC/vt_pixbuf_encode.mm" -o "$WORK/vtp.o" || exit 2
clang -fobjc-arc -O2 -c "$SRC/test_vt_pixbuf.m" -o "$WORK/test.o" || exit 2
clang++ "$WORK/vtp.o" "$WORK/test.o" \
  -framework Foundation -framework CoreVideo -framework VideoToolbox -framework CoreMedia \
  -o "$WORK/test_vt_pixbuf" || exit 2

for args in "1920 1080 0" "1920 1080 1" "4096 2304 0" "4096 2304 1"; do
  line=$("$WORK/test_vt_pixbuf" $args) || { echo "FAIL encode: $args"; fail=1; continue; }
  echo "  $line"
  if [ "$STRICT" = 1 ]; then
    echo "$line" | grep -q "keys=1" || { echo "  FAIL no keyframe: $args"; fail=1; }
  else
    echo "$line" | grep -qE "bytes=[1-9][0-9]*" || { echo "  FAIL no bitstream: $args"; fail=1; }
  fi
done

echo "== 2. submit CPU at 4K =="
line=$("$WORK/test_vt_pixbuf" 4096 2304 0)
cpu=$(echo "$line" | sed -E 's/.*cpu ([0-9.]+) ms.*/\1/')
echo "  cpu ${cpu} ms/frame"
# Hardware submits 4K in 0.16-0.33 ms. Hosted runners are shared VMs where the same call has been
# measured at 0.66 ms and at over 2 ms for no reason that has anything to do with this code, so the
# absolute bound only applies on hardware; the runner keeps a sanity ceiling.
if [ "$STRICT" = 1 ]; then SUBMIT_LIMIT=2.0; else SUBMIT_LIMIT=20.0; fi
awk -v c="$cpu" -v l="$SUBMIT_LIMIT" 'BEGIN { exit (c < l) ? 0 : 1 }' \
  || { echo "  FAIL 4K submit CPU above ${SUBMIT_LIMIT} ms/frame"; fail=1; }

echo "== 3. PSNR guard against the libyuv path =="
AB=$AB_ARG
if [ -z "$AB" ] || [ ! -f "$AB" ]; then
  echo "  SKIP (no encode_synth3.m supplied; pass it as \$1 to enable this check)"
else
  LIBYUV_INC=""
  LIBYUV_LIB=""
  # Take headers and library from the SAME base and stop at the first complete pair: mixing a
  # stale header tree with a newer library fails to compile (LIBYUV_BOOL, cpu_support.h).
  for base in "${LIBYUV_PREFIX:-}" "${VCPKG_ROOT:-}/installed/arm64-osx" /opt/homebrew "$HOME/rd-arm/bench/libyuv"; do
    [ -n "$base" ] || continue
    inc="" lib=""
    if [ -f "$base/include/libyuv.h" ] || [ -d "$base/include/libyuv" ]; then inc="$base/include"; fi
    for cand in "$base/lib/libyuv.a" "$base/lib/libyuv.dylib" "$base/libyuv.a"; do
      [ -f "$cand" ] && lib="$cand"
    done
    if [ -n "$inc" ] && [ -n "$lib" ]; then
      LIBYUV_INC="$inc"; LIBYUV_LIB="$lib"; break
    fi
  done
  if [ -z "$LIBYUV_INC" ] || [ -z "$LIBYUV_LIB" ]; then
    echo "  SKIP (libyuv not found)"
  else
    SDK=$(xcrun --show-sdk-path)
    # The harness includes "libyuv/include/libyuv.h" relative to its own directory, which would
    # force a header tree that may not match $LIBYUV_LIB. Rewrite that one include so both come
    # from the same installation.
    sed 's|#include "libyuv/include/libyuv.h"|#include <libyuv.h>|' "$AB" > "$WORK/ab.m"
    clang++ -x objective-c++ -O2 -fobjc-arc -isysroot "$SDK" -I"$SDK/usr/include/c++/v1" \
      -I"$LIBYUV_INC" "$WORK/ab.m" -x none "$LIBYUV_LIB" \
      -framework Foundation -framework CoreVideo -framework VideoToolbox -framework CoreMedia \
      -o "$WORK/ab" || { echo "  FAIL cannot build the A/B harness"; exit 2; }
    out=$("$WORK/ab" 40 h264 4096 2304 16 601)
    echo "$out" | grep -E "^current  |^direct  " | sed 's/^/  /'
    field() { echo "$1" | awk -v arm="^$2" -v key="$3" '$0 ~ arm { for (i = 1; i <= NF; i++) if ($i == key) print $(i + 1) }'; }
    cur=$(field "$out" current PSNR-Y)
    dir=$(field "$out" direct PSNR-Y)
    cu=$(field "$out" current PSNR-U)
    du=$(field "$out" direct PSNR-U)
    dv=$(field "$out" direct PSNR-V)
    echo "  psnr current=${cur:-?} direct=${dir:-?}  chroma direct U=${du:-?} V=${dv:-?}"
    if [ -z "${cur:-}" ] || [ -z "${dir:-}" ]; then
      echo "  FAIL could not parse PSNR"; fail=1
    else
      if [ "$STRICT" = 1 ]; then
        awk -v c="$cur" -v d="$dir" 'BEGIN { exit (c - d < 1.5) ? 0 : 1 }' \
          || { echo "  FAIL direct path drifted more than 1.5 dB (missing BT.601 tag?)"; fail=1; }
        # Bars scene only: text content legitimately sits near 34 dB on V (chroma siting, not a matrix bug).
        awk -v u="$du" -v v="$dv" 'BEGIN { exit (u >= 36 && v >= 40) ? 0 : 1 }' \
          || { echo "  FAIL chroma below 36/40 dB (direct U=$du V=$dv): colour matrix is wrong"; fail=1; }
      else
        awk -v d="$dir" 'BEGIN { exit (d >= 40) ? 0 : 1 }' \
          || { echo "  FAIL direct path below 40 dB (missing BT.601 tag?)"; fail=1; }
      fi
    fi
  fi
fi

echo "== result =="
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
