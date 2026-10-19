#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest installed iOS runtime.
set -euo pipefail

xcrun simctl list devices available -j | python3 -c '
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]


def runtime_version(name):
    match = re.search(r"iOS-(\d+)-(\d+)", name)
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)


for runtime in sorted((r for r in devices if "iOS" in r), key=runtime_version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone") and d.get("isAvailable", True)]
    # Prefer a plain "Pro" model: a typical screen size, not the biggest one.
    phones.sort(key=lambda d: (0 if "Pro" in d["name"] and "Max" not in d["name"] else 1, d["name"]))
    if phones:
        print(phones[0]["udid"])
        sys.exit(0)
sys.exit("no iPhone simulator found")
'
