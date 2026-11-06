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
CASES = [("joliet.iso", "joliet_manifest.json")]


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
        name, kind, size, _stamp = line.split("\t")
        out.append({"name": name, "is_dir": kind == "dir", "size": int(size)})
    return sorted(out, key=lambda e: e["name"])


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
    if failures:
        print("\n".join(failures))
        print("FAILED")
        sys.exit(1)
    print("ALL PASS (%d directories)" % checked)


if __name__ == "__main__":
    main()
