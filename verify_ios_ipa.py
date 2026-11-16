#!/usr/bin/env python3
"""Verify a device-only, arm64, externally signable IPA without Apple secrets."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import struct
import sys
import zipfile


CPU_TYPE_ARM64 = 0x0100000C
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
MACH_MAGICS = {
    b"\xcf\xfa\xed\xfe": "<",
    b"\xfe\xed\xfa\xcf": ">",
}
MACH32_MAGICS = {b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce"}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version_string(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def verify_thin(data, label):
    require(len(data) >= 32, f"Truncated Mach-O: {label}")
    endian = MACH_MAGICS.get(data[:4])
    require(endian is not None, f"Expected a 64-bit Mach-O: {label}")
    _, cpu, subtype, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from(
        endian + "8I", data
    )
    require(cpu == CPU_TYPE_ARM64, f"Non-arm64 Mach-O {label}: {cpu:#x}")
    require(ncmds > 0 and ncmds <= 4096, f"Invalid load command count: {label}")
    end = 32 + sizeofcmds
    require(end <= len(data), f"Truncated load commands: {label}")
    offset = 32
    builds = []
    for _ in range(ncmds):
        require(offset + 8 <= end, f"Truncated load command: {label}")
        cmd, size = struct.unpack_from(endian + "2I", data, offset)
        require(size >= 8 and offset + size <= end, f"Invalid load command: {label}")
        if cmd == LC_BUILD_VERSION:
            require(size >= 24, f"Truncated LC_BUILD_VERSION: {label}")
            platform, minimum, sdk, tools = struct.unpack_from(
                endian + "4I", data, offset + 8
            )
            require(24 + tools * 8 <= size, f"Invalid build tools list: {label}")
            require(platform == PLATFORM_IOS,
                    f"Not an iPhoneOS binary (platform={platform}): {label}")
            builds.append({"platform": "iPhoneOS", "minimum_os": version_string(minimum),
                           "sdk": version_string(sdk)})
        offset += size
    require(offset == end, f"Load command size mismatch: {label}")
    require(len(builds) == 1, f"Expected exactly one iOS LC_BUILD_VERSION: {label}")
    return {"architecture": "arm64", "cpu_subtype": subtype,
            "file_type": filetype, **builds[0]}


def verify_macho(data, label):
    fat = FAT_MAGICS.get(data[:4])
    if fat is None:
        return [verify_thin(data, label)]
    require(len(data) >= 8, f"Truncated fat header: {label}")
    endian, is_64 = fat
    count = struct.unpack_from(endian + "I", data, 4)[0]
    require(1 <= count <= 32, f"Invalid architecture count: {label}")
    entry_size = 32 if is_64 else 20
    require(8 + count * entry_size <= len(data), f"Truncated fat table: {label}")
    slices = []
    ranges = []
    for index in range(count):
        entry = 8 + index * entry_size
        cpu, _ = struct.unpack_from(endian + "2I", data, entry)
        offset, size = struct.unpack_from(endian + ("2Q" if is_64 else "2I"), data, entry + 8)
        require(cpu == CPU_TYPE_ARM64, f"Non-arm64 fat slice: {label}")
        require(offset >= 8 + count * entry_size and size >= 32 and offset + size <= len(data),
                f"Invalid fat slice range: {label}")
        require(all(offset + size <= start or offset >= finish for start, finish in ranges),
                f"Overlapping fat slices: {label}")
        ranges.append((offset, offset + size))
        slices.append(verify_thin(data[offset:offset + size], f"{label}[{index}]"))
    return slices


def load_plist(archive, path):
    try:
        result = plistlib.loads(archive.read(path))
    except (KeyError, plistlib.InvalidFileException) as error:
        raise ValueError(f"Missing or invalid plist: {path}") from error
    require(isinstance(result, dict), f"Expected dictionary plist: {path}")
    return result


def verify_ipa(path, expected_version=None, expected_build=None, expected_bundle_id=None):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP entries")
        for name in names:
            parts = PurePosixPath(name).parts
            require(not name.startswith("/") and "\\" not in name and ".." not in parts,
                    f"Unsafe archive path: {name}")
        corrupt = archive.testzip()
        require(corrupt is None, f"ZIP CRC failed: {corrupt}")
        require(not any(name.endswith("embedded.mobileprovision") for name in names),
                "Unexpected embedded provisioning profile in unsigned IPA")
        app_plists = [name for name in names if name.startswith("Payload/")
                      and name.endswith(".app/Info.plist") and len(name.split("/")) == 3]
        require(len(app_plists) == 1, "Expected exactly one Payload/*.app/Info.plist")
        app_plist = app_plists[0]
        app = app_plist.rsplit("/", 1)[0]
        info = load_plist(archive, app_plist)
        require(info.get("CFBundlePackageType") == "APPL", "Not an application bundle")
        require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"],
                "IPA is not for physical iOS devices")
        require(info.get("LSRequiresIPhoneOS") is True, "Missing LSRequiresIPhoneOS")
        require(isinstance(info.get("CFBundleIdentifier"), str) and info["CFBundleIdentifier"],
                "Missing bundle identifier")
        if expected_bundle_id is not None:
            require(info["CFBundleIdentifier"] == expected_bundle_id,
                    f"Wrong bundle identifier: {info['CFBundleIdentifier']}")
        for key, expected in (("CFBundleShortVersionString", expected_version),
                              ("CFBundleVersion", expected_build)):
            require(isinstance(info.get(key), str) and info[key], f"Missing {key}")
            if expected is not None:
                require(info[key] == expected, f"{key}: expected {expected}, got {info[key]}")
        executable = info.get("CFBundleExecutable", "")
        require(executable and "/" not in executable and "\\" not in executable,
                "Invalid application executable name")
        main_path = f"{app}/{executable}"
        require(main_path in names, "Missing application executable")
        binaries = {}
        for name in names:
            if not name.startswith(app + "/") or name.endswith("/"):
                continue
            with archive.open(name) as member:
                magic = member.read(4)
            if magic in MACH_MAGICS or magic in MACH32_MAGICS or magic in FAT_MAGICS:
                data = archive.read(name)
                binaries[name] = {"sha256": hashlib.sha256(data).hexdigest(),
                                  "slices": verify_macho(data, name)}
        require(main_path in binaries, "Application executable is not a valid Mach-O")
        require(all(item["file_type"] == 2 for item in binaries[main_path]["slices"]),
                "Main binary is not a Mach-O executable")
        framework_plists = [name for name in names
                            if name.startswith(app + "/Frameworks/")
                            and name.endswith(".framework/Info.plist")]
        frameworks = []
        for plist_path in framework_plists:
            framework = plist_path.rsplit("/", 1)[0]
            metadata = load_plist(archive, plist_path)
            platforms = metadata.get("CFBundleSupportedPlatforms")
            require(platforms is None or platforms == ["iPhoneOS"],
                    f"Framework is not for physical iOS devices: {framework}")
            framework_executable = metadata.get("CFBundleExecutable", "")
            require(framework_executable and "/" not in framework_executable
                    and "\\" not in framework_executable,
                    f"Invalid framework executable name: {framework}")
            binary = f"{framework}/{framework_executable}"
            require(binary in binaries, f"Missing or invalid framework executable: {binary}")
            require(all(item["file_type"] == 6 for item in binaries[binary]["slices"]),
                    f"Framework binary is not a Mach-O dylib: {binary}")
            frameworks.append(framework)
        require(f"{app}/Frameworks/App.framework" in frameworks, "Missing Flutter App.framework")
        require(f"{app}/Frameworks/Flutter.framework" in frameworks, "Missing Flutter engine framework")
        require(any(name.startswith(f"{app}/Frameworks/App.framework/flutter_assets/")
                    for name in names), "Missing Flutter asset bundle")
        minimum_os = info.get("MinimumOSVersion")
        require(isinstance(minimum_os, str) and minimum_os, "Missing minimum iOS version")
        with path.open("rb") as source:
            digest = hashlib.sha256()
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
            checksum = digest.hexdigest()
        return {
            "archive": path.name,
            "archive_bytes": path.stat().st_size,
            "sha256": checksum,
            "bundle_identifier": info["CFBundleIdentifier"],
            "display_name": info.get("CFBundleDisplayName", info.get("CFBundleName")),
            "version": info["CFBundleShortVersionString"],
            "build_number": info["CFBundleVersion"],
            "minimum_ios": minimum_os,
            "platform": "iPhoneOS",
            "architectures": ["arm64"],
            "embedded_provisioning_profile": False,
            "zip_crc_verified": True,
            "frameworks": sorted(frameworks),
            "binaries": binaries,
            "physical_device_runtime_tested": False,
            "requires_user_signing": True,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--expected-version")
    parser.add_argument("--expected-build")
    parser.add_argument("--expected-bundle-id")
    parser.add_argument("--source-revision")
    parser.add_argument("--upstream-revision")
    parser.add_argument("--flutter-version")
    parser.add_argument("--xcode-version")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        result = verify_ipa(args.ipa, args.expected_version, args.expected_build,
                            args.expected_bundle_id)
        result.update({
            "verified_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "source_revision": args.source_revision,
            "upstream_revision": args.upstream_revision,
            "implementation": "public",
            "flutter_version": args.flutter_version,
            "xcode_version": args.xcode_version,
        })
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n",
                                   encoding="utf-8")
        print(f"Verified {result['archive']}: arm64 iPhoneOS, iOS {result['minimum_ios']}+, "
              f"{len(result['binaries'])} Mach-O binaries; SHA256 {result['sha256']}")
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"IPA verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
