#!/usr/bin/env python3
"""Fail closed when a toolchain upgrade changes the shipped platform contract."""
import argparse
import plistlib
import re
import subprocess
from pathlib import Path


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"Invalid version: {value!r}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def validate_load_commands(output, minimum_os, sdk_version):
    fields = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] in {"platform", "minos", "sdk"}:
            if parts[0] in fields:
                raise ValueError("Ambiguous build metadata")
            fields[parts[0]] = parts[1]
    if fields.get("platform") != "MACOS":
        raise ValueError("Missing macOS build metadata")
    if version(fields.get("minos")) != version(minimum_os):
        raise ValueError(f"Binary deployment target differs from {minimum_os}")
    if version(fields.get("sdk")) != version(sdk_version):
        raise ValueError(f"Binary SDK differs from selected SDK {sdk_version}")


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def verify(app, minimum_os, sdk_version):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if version(info.get("LSMinimumSystemVersion")) != version(minimum_os):
        raise ValueError("Info.plist deployment target mismatch")
    if info.get("CFBundleExecutable") != "AgentDeck":
        raise ValueError("Unexpected bundle executable")
    binary = app / "Contents/MacOS/AgentDeck"
    architectures = set(command("/usr/bin/lipo", "-archs", str(binary)).split())
    if architectures != {"arm64", "x86_64"}:
        raise ValueError(f"Expected universal binary, found {sorted(architectures)}")
    for arch in sorted(architectures):
        output = command("/usr/bin/xcrun", "vtool", "-arch", arch,
                         "-show-build", str(binary))
        validate_load_commands(output, minimum_os, sdk_version)
    resources = app / "Contents/Resources"
    for name in ("agentdeckd.py", "VERSION", "AgentDeck_AgentDeckKit.bundle"):
        if not (resources / name).exists():
            raise ValueError(f"Missing bundled resource: {name}")
    print(f"Build metadata verified: arm64 + x86_64, deployment target {minimum_os}, "
          f"SDK {sdk_version}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--minimum-os", default="13.0")
    parser.add_argument("--sdk-version", required=True)
    args = parser.parse_args()
    try:
        verify(args.app, args.minimum_os, args.sdk_version)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Build metadata check failed: {exc}\n")
