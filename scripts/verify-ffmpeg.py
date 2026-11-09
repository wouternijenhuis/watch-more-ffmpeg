"""Inspect Artifacts/FFmpeg.xcframework and fail unless it is an LGPL-2.1-only, arm64 dynamic framework."""

import hashlib
import json
import plistlib
import re
import struct
import subprocess
import sys
from pathlib import Path

ARTIFACTS = Path(__file__).resolve().parent.parent / "Artifacts"
XCFRAMEWORK = ARTIFACTS / "FFmpeg.xcframework"
EXPECTED_SLICES = {
    "macos-arm64",
    "ios-arm64",
    "ios-arm64-simulator",
    "tvos-arm64",
    "tvos-arm64-simulator",
}
EXPECTED_INSTALL_NAME = "@rpath/FFmpeg.framework/FFmpeg"
MH_DYLIB = 6
CPU_TYPE_ARM64 = 0x0100000C
LC_ID_DYLIB = 0x0D
LC_BUILD_VERSION = 0x32
PLATFORMS = {1: "macos", 2: "ios", 3: "tvos", 6: "maccatalyst", 7: "iossimulator", 8: "tvossimulator"}


def macho_summary(data):
    """Return the single arm64 MH_DYLIB header facts, raising on anything else."""
    magic = data[:4]
    if magic != b"\xcf\xfa\xed\xfe":
        raise ValueError(f"Expected a thin 64-bit little-endian Mach-O, found magic {magic.hex()}")
    _, cpu, _, filetype, command_count, _, _, _ = struct.unpack_from("<IIIIIIII", data)
    if cpu != CPU_TYPE_ARM64:
        raise ValueError(f"Expected arm64 ({CPU_TYPE_ARM64:#x}), found {cpu:#x}")
    if filetype != MH_DYLIB:
        raise ValueError(f"Expected MH_DYLIB ({MH_DYLIB}), found {filetype}")
    offset = 32
    install_name = None
    platform = None
    min_os = None
    for _ in range(command_count):
        command, size = struct.unpack_from("<II", data, offset)
        if command == LC_ID_DYLIB:
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            raw = data[offset + name_offset:offset + size]
            install_name = raw.split(b"\0", 1)[0].decode("utf-8")
        elif command == LC_BUILD_VERSION:
            platform_id, minos = struct.unpack_from("<II", data, offset + 8)
            platform = PLATFORMS.get(platform_id, str(platform_id))
            min_os = f"{minos >> 16}.{(minos >> 8) & 0xFF}"
        offset += size
    if install_name is None:
        raise ValueError("No LC_ID_DYLIB load command")
    return {"cpuType": hex(cpu), "filetype": filetype, "installName": install_name, "platform": platform, "minOS": min_os}


def otool_install_name(binary):
    output = subprocess.run(["otool", "-D", str(binary)], capture_output=True, text=True, check=True).stdout
    return output.strip().splitlines()[-1].strip()


def license_flags(config_h):
    flags = {}
    for flag in ("CONFIG_GPL", "CONFIG_NONFREE", "CONFIG_VERSION3"):
        match = re.search(rf"^#define {flag} (\d)$", config_h, re.MULTILINE)
        if match is None:
            raise ValueError(f"{flag} is not defined in config.h")
        flags[flag] = int(match[1])
    return flags


def check_license(text):
    head = text[:200]
    if "GNU LESSER GENERAL PUBLIC LICENSE" not in head or "Version 2.1" not in head:
        raise ValueError("LICENSE is not the LGPL-2.1 text")


def find_framework_file(framework, name):
    candidates = [framework / name, framework / "Resources" / name, framework / "Versions" / "A" / "Resources" / name]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise ValueError(f"{framework} has no {name}")


def inspect_slice(entry):
    identifier = entry["LibraryIdentifier"]
    framework = XCFRAMEWORK / identifier / entry["LibraryPath"]
    binary = framework / "FFmpeg"
    data = binary.read_bytes()
    header = macho_summary(data)
    if header["installName"] != EXPECTED_INSTALL_NAME:
        raise ValueError(f"{identifier}: install name {header['installName']} != {EXPECTED_INSTALL_NAME}")
    otool_name = otool_install_name(binary)
    if otool_name != EXPECTED_INSTALL_NAME:
        raise ValueError(f"{identifier}: otool -D reports {otool_name}")
    config_path = ARTIFACTS / "config" / f"{identifier}-config.h"
    flags = license_flags(config_path.read_text(encoding="utf-8"))
    if any(flags.values()):
        raise ValueError(f"{identifier}: license flags are not all 0: {flags}")
    license_text = find_framework_file(framework, "LICENSE").read_text(encoding="utf-8")
    check_license(license_text)
    info = plistlib.loads(find_framework_file(framework, "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "net.devdad.watchmore.FFmpeg" or info.get("CFBundleExecutable") != "FFmpeg":
        raise ValueError(f"{identifier}: unexpected Info.plist identity")
    # App Store Connect rejects a bundle listing more than one platform (validation error 91177).
    expected_platform = {"ios-arm64": "iPhoneOS", "ios-arm64-simulator": "iPhoneSimulator", "tvos-arm64": "AppleTVOS",
                         "tvos-arm64-simulator": "AppleTVSimulator", "macos-arm64": "MacOSX"}.get(identifier)
    if info.get("CFBundleSupportedPlatforms") != [expected_platform]:
        raise ValueError(f"{identifier}: CFBundleSupportedPlatforms {info.get('CFBundleSupportedPlatforms')} != [{expected_platform}]")
    vt_path = ARTIFACTS / "config" / f"{identifier}-vt-filters.txt"
    return {
        "identifier": identifier,
        "framework": str(framework.relative_to(XCFRAMEWORK)),
        "binaryBytes": len(data),
        "binaryMiB": round(len(data) / (1024 * 1024), 2),
        "sha256": hashlib.sha256(data).hexdigest(),
        "header": header,
        "license": flags,
        "licenseSha256": hashlib.sha256(license_text.encode("utf-8")).hexdigest(),
        "version": info.get("CFBundleShortVersionString"),
        "hasPrivacyManifest": any((framework / p / "PrivacyInfo.xcprivacy").is_file() for p in (".", "Resources", "Versions/A/Resources")),
        "hasModuleMap": any((framework / p / "module.modulemap").is_file() for p in ("Modules", "Versions/A/Modules")),
        "videoToolboxFilters": vt_path.read_text(encoding="utf-8").strip() if vt_path.is_file() else "unknown",
    }


def inspect():
    info = plistlib.loads((XCFRAMEWORK / "Info.plist").read_bytes())
    entries = info["AvailableLibraries"]
    found = {entry["LibraryIdentifier"] for entry in entries}
    if found != EXPECTED_SLICES:
        raise ValueError(f"Slices {sorted(found)} != expected {sorted(EXPECTED_SLICES)}")
    slices = [inspect_slice(entry) for entry in sorted(entries, key=lambda e: e["LibraryIdentifier"])]
    return {"xcframework": str(XCFRAMEWORK), "ok": True, "slices": slices}


if __name__ == "__main__":
    try:
        report = inspect()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, struct.error) as error:
        print(json.dumps({"ok": False, "error": str(error)}, indent=2))
        sys.exit(1)
    print(json.dumps(report, indent=2))
