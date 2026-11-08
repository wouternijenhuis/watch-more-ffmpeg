#!/usr/bin/env bash
# Build a dynamically linked, LGPL-2.1-only FFmpeg.xcframework for the Media Bridge spike.
#
# Usage: build-ffmpeg.sh [slice...]
#   slices: macos-arm64 ios-arm64 ios-arm64-simulator tvos-arm64 tvos-arm64-simulator
#   No arguments builds all five and (re)creates the xcframework from every slice that has a framework.
#
# Everything lives under packages/swift/MediaBridge: sources and per-slice build trees in
# .ffmpeg-build/ and the results in Artifacts/ (both gitignored). Re-running skips the verified
# download and extraction and rebuilds only the slices you name.
set -euo pipefail

FFMPEG_VERSION="9.0.2"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
# gpg is not installed, so pin the tarball by SHA-256 (the value Homebrew's formula pins for this URL).
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$PACKAGE_DIR/.ffmpeg-build"
ARTIFACTS_DIR="$PACKAGE_DIR/Artifacts"
TARBALL="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SOURCE_PARENT="$WORK_DIR/src"
SOURCE_DIR="$SOURCE_PARENT/ffmpeg-${FFMPEG_VERSION}"
EXTRACT_STAMP="$SOURCE_PARENT/.extracted-${FFMPEG_SHA256}"
JOBS="$(sysctl -n hw.ncpu)"
BUNDLE_ID="net.devdad.watchmore.FFmpeg"
ALL_SLICES=(macos-arm64 ios-arm64 ios-arm64-simulator tvos-arm64 tvos-arm64-simulator)

# slice -> "sdk|clang target|platform family"
slice_spec() {
  case "$1" in
    macos-arm64)             echo "macosx|arm64-apple-macos14.0|macos" ;;
    ios-arm64)               echo "iphoneos|arm64-apple-ios17.0|ios" ;;
    ios-arm64-simulator)     echo "iphonesimulator|arm64-apple-ios17.0-simulator|ios" ;;
    tvos-arm64)              echo "appletvos|arm64-apple-tvos17.0|tvos" ;;
    tvos-arm64-simulator)    echo "appletvsimulator|arm64-apple-tvos17.0-simulator|tvos" ;;
    *) echo "Unknown slice: $1" >&2; return 1 ;;
  esac
}

# Components. Names configure does not know in this FFmpeg version are dropped and reported
# (see filter_known), never substituted.
DEMUXERS=(matroska mov mpegts avi flv asf mpegps mp3 aac ac3 eac3 dts flac ogg wav h264 hevc mpegvideo srt ass webvtt)
MUXERS=(mp4 mov webvtt)
PARSERS=(h264 hevc aac aac_latm ac3 mpegaudio mpegvideo mpeg4video dca vc1 vp8 vp9 flac opus vorbis av1 dvbsub dvdsub)
BSFS=(aac_adtstoasc extract_extradata vp9_superframe_split mpeg4_unpack_bframes h264_mp4toannexb hevc_mp4toannexb dovi_rpu setts)
DECODERS=(
  aac aac_latm ac3 eac3 dca truehd mlp mp1 mp2 mp3 mp1float mp2float mp3float opus vorbis flac alac
  wmav1 wmav2 wmapro pcm_s16le pcm_s16be pcm_s24le pcm_bluray pcm_dvd
  h264 hevc mpeg1video mpeg2video mpeg4 msmpeg4v3 h263 vc1 wmv1 wmv2 wmv3 vp8 vp9
  subrip ass ssa webvtt mov_text dvbsub dvdsub pgssub
)
ENCODERS=(aac ac3 eac3 h264_videotoolbox hevc_videotoolbox webvtt)
HWACCELS=(h264_videotoolbox hevc_videotoolbox mpeg2_videotoolbox mpeg4_videotoolbox vp9_videotoolbox)
FILTERS=(buffer buffersink abuffer abuffersink bwdif yadif scale format aformat aresample null anull setpts)
VT_FILTERS=(bwdif_videotoolbox yadif_videotoolbox scale_vt)
PROTOCOLS=(file)

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

fetch_and_extract() {
  mkdir -p "$WORK_DIR" "$SOURCE_PARENT"
  if [[ ! -f "$TARBALL" || "$(sha256_of "$TARBALL")" != "$FFMPEG_SHA256" ]]; then
    log "Downloading $FFMPEG_URL"
    curl -fSL --retry 3 -o "$TARBALL.part" "$FFMPEG_URL"
    mv "$TARBALL.part" "$TARBALL"
  fi
  local actual
  actual="$(sha256_of "$TARBALL")"
  if [[ "$actual" != "$FFMPEG_SHA256" ]]; then
    rm -f "$TARBALL"
    die "SHA-256 mismatch for $FFMPEG_URL: expected $FFMPEG_SHA256, got $actual"
  fi
  if [[ ! -f "$EXTRACT_STAMP" || ! -x "$SOURCE_DIR/configure" ]]; then
    log "Extracting into $SOURCE_PARENT"
    rm -rf "$SOURCE_DIR"
    find "$SOURCE_PARENT" -maxdepth 1 -name '.extracted-*' -delete
    tar -xf "$TARBALL" -C "$SOURCE_PARENT"
    touch "$EXTRACT_STAMP"
  fi
}

# filter_known <configure list kind> <result array name> <component...>
# Keeps the components this FFmpeg's configure lists; prints and records the rest as dropped.
filter_known() {
  local kind="$1" out="$2"; shift 2
  local available=" $("$SOURCE_DIR/configure" "--list-$kind" | tr '\n' ' ') "
  local known_items=() name
  for name in "$@"; do
    if [[ "$available" == *" $name "* ]]; then
      known_items+=("$name")
    else
      echo "dropped $kind: $name (not selectable in FFmpeg $FFMPEG_VERSION)" | tee -a "$WORK_DIR/dropped-components.txt" >&2
    fi
  done
  eval "$out=(\${known_items[@]+\"\${known_items[@]}\"})"
}

COMPONENT_FLAGS=()
prepare_component_flags() {
  : > "$WORK_DIR/dropped-components.txt"
  COMPONENT_FLAGS=()
  add_flags() { # kind flag-name array-name
    local kept=() item
    filter_known "$1" kept "${@:3}"
    for item in "${kept[@]}"; do COMPONENT_FLAGS+=("--enable-$2=$item"); done
  }
  add_flags demuxers demuxer "${DEMUXERS[@]}"
  add_flags muxers muxer "${MUXERS[@]}"
  add_flags parsers parser "${PARSERS[@]}"
  add_flags bsfs bsf "${BSFS[@]}"
  add_flags decoders decoder "${DECODERS[@]}"
  add_flags encoders encoder "${ENCODERS[@]}"
  add_flags hwaccels hwaccel "${HWACCELS[@]}"
  add_flags filters filter "${FILTERS[@]}"
  add_flags protocols protocol "${PROTOCOLS[@]}"
  # Filters that are not selectable are always built into libavfilter in this release; the smoke test
  # and verifier prove that rather than this script assuming it.
}

assert_lgpl_config() {
  local config_h="$1" flag
  for flag in CONFIG_GPL CONFIG_NONFREE CONFIG_VERSION3; do
    grep -Eq "^#define $flag 0\$" "$config_h" || die "$config_h does not define $flag 0; refusing to continue (license must stay LGPL-2.1-only)"
  done
}

write_info_plist() { # path family
  local path="$1" family="$2" platforms min_key min_value
  case "$family" in
    macos) platforms="MacOSX"; min_key="LSMinimumSystemVersion"; min_value="14.0" ;;
    ios)   platforms="iPhoneOS iPhoneSimulator"; min_key="MinimumOSVersion"; min_value="17.0" ;;
    tvos)  platforms="AppleTVOS AppleTVSimulator"; min_key="MinimumOSVersion"; min_value="17.0" ;;
  esac
  {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>FFmpeg</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>FFmpeg</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$FFMPEG_VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>$min_key</key>
	<string>$min_value</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
PLIST
    local platform
    for platform in $platforms; do echo "		<string>$platform</string>"; done
    cat <<PLIST
	</array>
</dict>
</plist>
PLIST
  } > "$path"
}

write_privacy_manifest() {
  cat > "$1" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array/>
</dict>
</plist>
PLIST
}

write_umbrella_header() {
  cat > "$1" <<'HEADER'
#ifndef FFMPEG_UMBRELLA_H
#define FFMPEG_UMBRELLA_H

#include "libavformat/avformat.h"
#include "libavformat/avio.h"
#include "libavcodec/avcodec.h"
#include "libavcodec/bsf.h"
#include "libavutil/avutil.h"
#include "libavutil/opt.h"
#include "libavutil/channel_layout.h"
#include "libavutil/audio_fifo.h"
#include "libavutil/hwcontext.h"
#include "libavutil/pixdesc.h"
#include "libavutil/mathematics.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/timestamp.h"
#include "libavfilter/avfilter.h"
#include "libavfilter/buffersink.h"
#include "libavfilter/buffersrc.h"
#include "libswresample/swresample.h"
#include "libswscale/swscale.h"

#endif
HEADER
}

# Configure one slice. Tries the VideoToolbox/Metal filters first and falls back, recording the outcome.
configure_slice() { # slice sdk target
  local slice="$1" sdk="$2" target="$3"
  local slice_dir="$WORK_DIR/$slice" sysroot clang_path
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  clang_path="$(xcrun --sdk "$sdk" --find clang)"
  local -a base=(
    --enable-cross-compile --target-os=darwin --arch=aarch64
    "--cc=$clang_path" "--ld=$clang_path" "--sysroot=$sysroot"
    "--extra-cflags=-target $target -isysroot $sysroot -fno-common"
    "--extra-ldflags=-target $target -isysroot $sysroot"
    "--prefix=$slice_dir/install"
    --disable-everything --disable-programs --disable-doc --disable-network --disable-avdevice
    --disable-autodetect
    --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib
    --enable-static --disable-shared --enable-pic --disable-debug --disable-iconv
  )
  # License is the hard requirement: these three must never be passed.
  local flag
  for flag in "${base[@]}"; do
    case "$flag" in --enable-gpl|--enable-nonfree|--enable-version3) die "forbidden configure flag $flag" ;; esac
  done

  prepare_component_flags
  local vt_known=()
  filter_known filters vt_known "${VT_FILTERS[@]}"

  # Candidate filter sets, richest first. Metal needs the Metal toolchain; scale_vt does not.
  local -a attempts=()
  local -a vt_all=() vt_scale=()
  local item
  for item in "${vt_known[@]}"; do
    vt_all+=("--enable-filter=$item")
    [[ "$item" == scale_vt ]] && vt_scale+=("--enable-filter=$item")
  done
  local result="none"
  rm -rf "$slice_dir"
  mkdir -p "$slice_dir/build"
  local attempt_name attempt_flags
  for attempt_name in all scale_vt_only none; do
    local -a extra=()
    case "$attempt_name" in
      all)           [[ ${#vt_all[@]} -gt 0 ]] || continue; extra=("--enable-metal" "${vt_all[@]}") ;;
      scale_vt_only) [[ ${#vt_scale[@]} -gt 0 ]] || continue; extra=("${vt_scale[@]}") ;;
      none)          extra=() ;;
    esac
    log "[$slice] configure (VT filters: $attempt_name)"
    rm -rf "$slice_dir/build"; mkdir -p "$slice_dir/build"
    local line=("$SOURCE_DIR/configure" "${base[@]}" "${COMPONENT_FLAGS[@]}" ${extra[@]+"${extra[@]}"})
    if (cd "$slice_dir/build" && "${line[@]}") > "$slice_dir/configure.log" 2>&1; then
      result="$attempt_name"
      printf '%q ' "${line[@]}" > "$slice_dir/configure-line.txt"; echo >> "$slice_dir/configure-line.txt"
      break
    fi
    tail -5 "$slice_dir/configure.log" | sed "s/^/[$slice] /" >&2
  done
  [[ "$result" != none || -f "$slice_dir/configure-line.txt" ]] || die "[$slice] configure failed; see $slice_dir/configure.log"
  assert_lgpl_config "$slice_dir/build/config.h"
  echo "$result" > "$slice_dir/vt-filters.txt"
  log "[$slice] configure ok; VT filters: $result"
}

link_framework() { # slice sdk target family
  local slice="$1" sdk="$2" target="$3" family="$4"
  local slice_dir="$WORK_DIR/$slice" sysroot clang_path
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  clang_path="$(xcrun --sdk "$sdk" --find clang)"
  local install="$slice_dir/install" fw_root="$slice_dir/framework/FFmpeg.framework"
  local bin_dir res_dir header_dir
  rm -rf "$slice_dir/framework"
  if [[ "$family" == macos ]]; then
    bin_dir="$fw_root/Versions/A"; res_dir="$bin_dir/Resources"
  else
    bin_dir="$fw_root"; res_dir="$fw_root"
  fi
  header_dir="$bin_dir/Headers"
  mkdir -p "$bin_dir" "$res_dir" "$header_dir" "$bin_dir/Modules"

  local -a libs=()
  local library
  # FFmpeg 9 compiles libavfilter's framepool.c into libswscale as well; -all_load would then see every
  # ff_frame_pool_* symbol twice. Link a copy of libswscale without it (libavfilter keeps the same code).
  mkdir -p "$slice_dir/link-libs"
  cp "$install/lib/libswscale.a" "$slice_dir/link-libs/libswscale.a"
  ar d "$slice_dir/link-libs/libswscale.a" framepool.o
  for library in avformat avcodec avfilter swresample avutil; do libs+=("$install/lib/lib$library.a"); done
  libs+=("$slice_dir/link-libs/libswscale.a")
  local -a frameworks=(-framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation -framework AudioToolbox -framework QuartzCore)
  [[ "$family" == macos ]] && frameworks+=(-framework CoreServices)
  [[ "$(cat "$slice_dir/vt-filters.txt")" == all ]] && frameworks+=(-framework Metal)

  log "[$slice] linking FFmpeg dylib"
  "$clang_path" -dynamiclib -target "$target" -isysroot "$sysroot" \
    -install_name "@rpath/FFmpeg.framework/FFmpeg" \
    -compatibility_version 1.0.0 -current_version "$FFMPEG_VERSION" \
    -Wl,-all_load "${libs[@]}" "${frameworks[@]}" -lz -lbz2 -lm \
    -o "$bin_dir/FFmpeg"
  strip -x "$bin_dir/FFmpeg"

  local lib
  for lib in libavformat libavcodec libavutil libavfilter libswresample libswscale; do
    cp -R "$install/include/$lib" "$header_dir/"
  done
  # FFmpeg headers include each other as "libavutil/x.h", which only resolves with -I on Headers.
  # Point those at the framework (<FFmpeg/libavutil/x.h>) so consumers need nothing but -F.
  find "$header_dir" -name '*.h' -exec perl -pi -e 's{^(\s*#\s*include\s+)"((?:libav|libsw)[a-z]*/[^"]+)"}{$1<FFmpeg/$2>}' {} +
  write_umbrella_header "$header_dir/FFmpeg.h"
  printf 'framework module FFmpeg {\n    umbrella header "FFmpeg.h"\n    export *\n}\n' > "$bin_dir/Modules/module.modulemap"
  write_info_plist "$res_dir/Info.plist" "$family"
  write_privacy_manifest "$res_dir/PrivacyInfo.xcprivacy"
  cp "$SOURCE_DIR/COPYING.LGPLv2.1" "$res_dir/LICENSE"

  if [[ "$family" == macos ]]; then
    ln -s A "$fw_root/Versions/Current"
    ln -s Versions/Current/FFmpeg "$fw_root/FFmpeg"
    ln -s Versions/Current/Headers "$fw_root/Headers"
    ln -s Versions/Current/Modules "$fw_root/Modules"
    ln -s Versions/Current/Resources "$fw_root/Resources"
  fi

  # Prove the umbrella header compiles as a clang module for this slice.
  local module_check="$slice_dir/module-check"
  rm -rf "$module_check"; mkdir -p "$module_check"
  printf '@import FFmpeg;\nint main(void) { return avformat_version() ? 0 : 1; }\n' > "$module_check/check.m"
  "$clang_path" -target "$target" -isysroot "$sysroot" -fmodules -fmodules-cache-path="$module_check/cache" \
    -F "$slice_dir/framework" -fsyntax-only -Wno-deprecated-declarations -Wno-incomplete-umbrella "$module_check/check.m" \
    || die "[$slice] umbrella header does not compile as a module"

  mkdir -p "$ARTIFACTS_DIR/config"
  cp "$slice_dir/build/config.h" "$ARTIFACTS_DIR/config/$slice-config.h"
  cp "$slice_dir/vt-filters.txt" "$ARTIFACTS_DIR/config/$slice-vt-filters.txt"
}

build_slice() {
  local slice="$1" spec sdk target family
  spec="$(slice_spec "$slice")"
  IFS='|' read -r sdk target family <<< "$spec"
  local slice_dir="$WORK_DIR/$slice"
  configure_slice "$slice" "$sdk" "$target"
  log "[$slice] make -j$JOBS"
  (cd "$slice_dir/build" && make -j"$JOBS" > "$slice_dir/make.log" 2>&1 && make install > "$slice_dir/install.log" 2>&1) \
    || { tail -30 "$slice_dir/make.log" >&2; die "[$slice] build failed; see $slice_dir/make.log"; }
  link_framework "$slice" "$sdk" "$target" "$family"
}

package_xcframework() {
  local -a args=()
  local slice
  for slice in "${ALL_SLICES[@]}"; do
    [[ -d "$WORK_DIR/$slice/framework/FFmpeg.framework" ]] && args+=(-framework "$WORK_DIR/$slice/framework/FFmpeg.framework")
  done
  [[ ${#args[@]} -gt 0 ]] || die "no built slices to package"
  if [[ ${#args[@]} -ne $((2 * ${#ALL_SLICES[@]})) ]]; then
    echo "warning: packaging only $((${#args[@]} / 2)) of ${#ALL_SLICES[@]} slices" >&2
  fi
  mkdir -p "$ARTIFACTS_DIR"
  rm -rf "$ARTIFACTS_DIR/FFmpeg.xcframework"
  xcodebuild -create-xcframework "${args[@]}" -output "$ARTIFACTS_DIR/FFmpeg.xcframework"

  # Record the exact configure line and the configure summary for one slice.
  local reference="macos-arm64"
  [[ -f "$WORK_DIR/$reference/configure-line.txt" ]] || reference="$(ls "$WORK_DIR" | grep -E '^(macos|ios|tvos)' | head -1)"
  {
    echo "# FFmpeg $FFMPEG_VERSION configure for slice $reference (run from an empty build directory)"
    echo "# License: LGPL-2.1-only (no --enable-gpl, --enable-nonfree or --enable-version3)"
    echo
    echo "## Configure line"
    cat "$WORK_DIR/$reference/configure-line.txt"
    echo
    echo "## VideoToolbox/Metal filters per slice (all = bwdif/yadif/scale VT filters that exist; none = dropped)"
    for slice in "${ALL_SLICES[@]}"; do
      [[ -f "$WORK_DIR/$slice/vt-filters.txt" ]] && echo "$slice: $(cat "$WORK_DIR/$slice/vt-filters.txt")"
    done
    echo
    echo "## Components dropped because configure does not list them"
    cat "$WORK_DIR/dropped-components.txt"
    echo
    echo "## Configure summary ($reference)"
    cat "$WORK_DIR/$reference/configure.log"
  } > "$ARTIFACTS_DIR/FFmpeg-configure.txt"
  log "Wrote $ARTIFACTS_DIR/FFmpeg.xcframework"
}

main() {
  local -a slices=("$@")
  [[ ${#slices[@]} -gt 0 ]] || slices=("${ALL_SLICES[@]}")
  local slice
  for slice in "${slices[@]}"; do slice_spec "$slice" > /dev/null; done
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  fetch_and_extract
  mkdir -p "$ARTIFACTS_DIR"
  local started=$SECONDS
  for slice in "${slices[@]}"; do build_slice "$slice"; done
  package_xcframework
  log "Done in $((SECONDS - started))s"
}

main "$@"
