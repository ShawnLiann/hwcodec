#!/bin/bash
# CI-only copy of NOTES/run-check.sh for the fork's macOS runner.
#
# Why a copy exists: NOTES/ is excluded from every worktree on this host
# (`info/exclude` → /NOTES/), so the workflow cannot call the original file
# without publishing the whole notes tree. This copy carries the same steps and
# lives only on the scratch branch `ci/macos-run-check-<date>`; it is never part
# of the change under review.
#
# Difference from the local script: the scratch root comes from $RUNNER_TEMP on
# CI (and falls back to the local scratch when run by hand), and the ffmpeg build
# is cached between runs by the workflow, not by this script.
#
# `--disable-iconv` is load-bearing on CI: configure autodetects iconv and then
# avcodec's decode.o references iconv_open/iconv_close, which the final link does
# not resolve on arm64 macOS (measured: run 44873767144, "Undefined symbols for
# architecture arm64: _iconv_close ... _ff_decode_preinit"). Nothing in the
# surface path needs charset conversion, so it is turned off instead of adding
# -liconv to a link line build.rs owns.
#
# Usage: bash ci/run-check-macos.sh       Exit: 0 = linked and all tests passed.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
S=${REGROW_SCRATCH:-${RUNNER_TEMP:-$HOME/.hermes/cache/scratch}/regrow-compile}
FFVER=7.1.1
FF=$S/ffmpeg-$FFVER
PREFIX=$S/ff7
VP=$S/ff7-vcpkg

if [ ! -f "$PREFIX/lib/libavcodec.a" ]; then
  echo "# building ffmpeg $FFVER static (once)"
  mkdir -p "$S"
  if [ ! -d "$FF/configure" ]; then
    [ -f "$S/ffmpeg.tar.xz" ] || curl -sSLf -o "$S/ffmpeg.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFVER.tar.xz" || exit 2
    tar xf "$S/ffmpeg.tar.xz" -C "$S" || exit 2
  fi
  cd "$FF" || exit 2
  ./configure --prefix="$PREFIX" --disable-programs --disable-doc --disable-everything \
    --disable-shared --enable-static --enable-decoder=h264,hevc \
    --enable-parser=h264,hevc --enable-hwaccel=h264_videotoolbox --enable-videotoolbox \
    --disable-iconv || exit 2
  make -j"$(sysctl -n hw.ncpu)" && make install || exit 2
fi

# build.rs wants a vcpkg-shaped installed/<triplet>/{include,lib}
ARCH=x64-osx; [ "$(uname -m)" = arm64 ] && ARCH=arm64-osx
mkdir -p "$VP/installed/$ARCH"
ln -sfn "$PREFIX/include" "$VP/installed/$ARCH/include"
ln -sfn "$PREFIX/lib" "$VP/installed/$ARCH/lib"

export VCPKG_ROOT="$VP"
export LIBCLANG_PATH=${LIBCLANG_PATH:-$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$S/target-run}
cd "$REPO" || exit 2
echo "# ci run-check $(git rev-parse --short HEAD) on ffmpeg $FFVER ($ARCH) / $(uname -m) / $(sw_vers -productVersion)"
cargo test --test macos_surface -- --nocapture --test-threads=1 2>&1 | grep -v "^ *ld: warning" | tail -40
exit "${PIPESTATUS[0]}"
