#!/bin/bash
# Encode-side zero-copy verification. Runs on a macOS runner (needs Xcode CLT, not vcpkg).
#
#   scripts/verify-encode-zerocopy.sh [path-to-encode_synth3.m]
#
# Guards, in order:
#   1. the wrapper compiles and encodes: keyframe present, non-zero bitstream, every frame delivered
#   2. submit CPU at 4K stays below 2 ms/frame (a regression here means the pixel buffer path became
#      a copy again)
#   3. with libyuv available (vcpkg or brew), the BGRA-direct stream must stay within 1.5 dB of the
#      libyuv path. This is the check that catches a missing BT.601 attachment -- it fails hard at
#      ~27.6 dB when the tag is absent.
set -uo pipefail
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
  echo "$line" | grep -q "keys=1" || { echo "  FAIL no keyframe: $args"; fail=1; }
done

echo "== 2. submit CPU at 4K =="
line=$("$WORK/test_vt_pixbuf" 4096 2304 0)
cpu=$(echo "$line" | sed -E 's/.*cpu ([0-9.]+) ms.*/\1/')
echo "  cpu ${cpu} ms/frame"
awk -v c="$cpu" 'BEGIN { exit (c < 2.0) ? 0 : 1 }' || { echo "  FAIL 4K submit CPU above 2 ms/frame"; fail=1; }

echo "== 3. PSNR guard against the libyuv path =="
AB=${1:-}
if [ -z "$AB" ] || [ ! -f "$AB" ]; then
  echo "  SKIP (no encode_synth3.m supplied; pass it as \$1 to enable this check)"
else
  LIBYUV_INC=""
  LIBYUV_LIB=""
  for base in "${VCPKG_ROOT:-}/installed/arm64-osx" /opt/homebrew "$HOME/rd-arm/bench/libyuv"; do
    [ -d "$base/include/libyuv" ] && LIBYUV_INC="$base/include"
    [ -f "$base/include/libyuv.h" ] && LIBYUV_INC="$base/include"
    for cand in "$base/lib/libyuv.a" "$base/lib/libyuv.dylib" "$base/libyuv.a"; do
      [ -f "$cand" ] && LIBYUV_LIB="$cand"
    done
    [ -n "$LIBYUV_INC" ] && [ -n "$LIBYUV_LIB" ] && break
  done
  if [ -z "$LIBYUV_INC" ] || [ -z "$LIBYUV_LIB" ]; then
    echo "  SKIP (libyuv not found)"
  else
    SDK=$(xcrun --show-sdk-path)
    clang++ -x objective-c++ -O2 -fobjc-arc -isysroot "$SDK" -I"$SDK/usr/include/c++/v1" \
      -I"$LIBYUV_INC" "$AB" -x none "$LIBYUV_LIB" \
      -framework Foundation -framework CoreVideo -framework VideoToolbox -framework CoreMedia \
      -o "$WORK/ab" || { echo "  FAIL cannot build the A/B harness"; exit 2; }
    out=$("$WORK/ab" 40 h264 4096 2304 16 601)
    echo "$out" | grep -E "^current  |^direct  " | sed 's/^/  /'
    cur=$(echo "$out" | sed -nE 's/^current .*PSNR-Y ([0-9.]+) dB/\1/p')
    dir=$(echo "$out" | sed -nE 's/^direct .*PSNR-Y ([0-9.]+) dB/\1/p')
    echo "  psnr current=${cur:-?} direct=${dir:-?}"
    if [ -z "${cur:-}" ] || [ -z "${dir:-}" ]; then
      echo "  FAIL could not parse PSNR"; fail=1
    else
      awk -v c="$cur" -v d="$dir" 'BEGIN { exit (c - d < 1.5) ? 0 : 1 }' \
        || { echo "  FAIL direct path drifted more than 1.5 dB (missing BT.601 tag?)"; fail=1; }
    fi
  fi
fi

echo "== result =="
[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
