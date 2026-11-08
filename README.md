# FFmpeg for Watch More

A prebuilt, **LGPL-2.1** build of [FFmpeg](https://ffmpeg.org) 9.0.2 as an Apple
`FFmpeg.xcframework`. It is used by the Media Bridge in the Watch More app for iPhone, iPad and
Apple TV, which turns streams AVPlayer can't open into HLS for AVPlayer.

It is built once on a Mac and published as a release asset. The app's Swift package downloads it
by URL and SHA-256 checksum; nothing builds FFmpeg in CI. This repository has no workflows.

## What is in a release

| Asset | What it is |
|---|---|
| `FFmpeg.xcframework.zip` | Dynamic frameworks for `ios-arm64`, `ios-arm64-simulator`, `tvos-arm64`, `tvos-arm64-simulator` and `macos-arm64` |
| `ffmpeg-9.0.2.tar.xz` | The unmodified FFmpeg 9.0.2 source the frameworks were built from (SHA-256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`, as published on ffmpeg.org) |
| `FFmpeg-configure.txt` | The exact `configure` line for every slice |

## Licence and source

FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 (see
`COPYING.LGPLv2.1`). This build is configured **without** `--enable-gpl`, `--enable-nonfree` and
`--enable-version3`, and is linked dynamically, so it stays under LGPL-2.1.
`scripts/verify-ffmpeg.py` checks both for every slice.

The FFmpeg source is not modified. The only post-processing rewrites `#include` paths in the
installed public headers so they resolve inside the framework (`scripts/build-ffmpeg.sh`). The
complete corresponding source is attached to each release next to the binaries, and
`scripts/build-ffmpeg.sh` rebuilds the same frameworks from it.

The scripts in this repository are released under the same LGPL-2.1 terms.

## Rebuilding

On a Mac with Xcode:

```bash
scripts/build-ffmpeg.sh
python3 -I scripts/verify-ffmpeg.py
```

The build script downloads the pinned tarball and refuses one that doesn't match its SHA-256.
For a new release, zip the framework with
`ditto -c -k --sequesterRsrc --keepParent FFmpeg.xcframework FFmpeg.xcframework.zip`, compute
`swift package compute-checksum FFmpeg.xcframework.zip`, upload both, and update the URL and
checksum in Watch More's `packages/swift/FFmpegBinary/Package.swift`.
