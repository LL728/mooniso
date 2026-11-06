#!/usr/bin/env python3
"""与本机独立实现（pycdlib）的目录清单对拍。

    python tools/gen_fixtures_pycdlib.py   # 先生成映像与基准清单
    python tools/check_compat.py

对拍内容：每个目录下的 (名字, 是否目录, 大小) 集合，本库 CLI 输出必须与 pycdlib 一致。
"""

import json
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXPECTED = os.path.join(ROOT, "tools", "expected")

# (映像, pycdlib 基准清单)
CASES = [
    ("joliet.iso", "joliet_manifest.json"),
    ("rockridge.iso", "rockridge_manifest.json"),
]

# El Torito 启动项基准（由 pycdlib 导出）
BOOT_CASE = ("boot.iso", "boot_manifest.json")


def run_cli(args):
    cmd = ["moon", "run", "--target", "js", "cmd/main", "--"] + args
    proc = subprocess.run(
        cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    if proc.returncode != 0:
        print("CLI 退出码 %d: %s" % (proc.returncode, proc.stderr.strip()))
        sys.exit(2)
    return proc.stdout


def cli_entries(image, directory):
    out = []
    for line in run_cli(["ls", image, directory]).splitlines():
        if not line:
            continue
        fields = line.split("\t")
        name, kind, size = fields[0], fields[1], int(fields[2])
        out.append(
            {
                "name": name,
                "is_dir": kind == "dir",
                "is_symlink": kind == "link",
                "size": size,
            }
        )
    return sorted(out, key=lambda e: e["name"])


def check_boot(failures):
    image, manifest_name = BOOT_CASE
    with open(os.path.join(EXPECTED, manifest_name), encoding="utf-8") as f:
        want = json.load(f)
    got = {}
    for line in run_cli(["info", "tools/corpus/" + image]).splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            got[key] = value
    if got.get("bootable") != str(want["bootable"]).lower():
        failures.append("bootable 不一致: cli=%s pycdlib=%s" % (got.get("bootable"), want["bootable"]))
    for cli_key, want_key in (
        ("boot_platform", "platform_id"),
        ("boot_media", "media_type"),
        ("boot_sectors", "sector_count"),
        ("boot_load_lba", "load_lba"),
    ):
        if got.get(cli_key) != str(want[want_key]):
            failures.append(
                "%s 不一致: cli=%s pycdlib=%s" % (cli_key, got.get(cli_key), want[want_key])
            )
    if not failures:
        print("ok   %s boot catalog matches pycdlib" % image)


def main():
    failures = []
    checked = 0
    for image, manifest_name in CASES:
        image_path = "tools/corpus/" + image
        with open(os.path.join(EXPECTED, manifest_name), encoding="utf-8") as f:
            tree = json.load(f)
        for directory, want in sorted(tree.items()):
            path = "/" if directory == "/" else directory
            got = cli_entries(image_path, path)
            want_sorted = sorted(want, key=lambda e: e["name"])
            if got != want_sorted:
                failures.append(
                    "%s %s 与 pycdlib 不一致:\n  cli     = %s\n  pycdlib = %s"
                    % (image, path, got, want_sorted)
                )
            else:
                checked += 1
                print("ok   %s %s (%d entries)" % (image, path, len(got)))
    check_boot(failures)
    if failures:
        print("\n".join(failures))
        print("FAILED")
        sys.exit(1)
    print("ALL PASS (%d directories)" % checked)


if __name__ == "__main__":
    main()
