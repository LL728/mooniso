#!/usr/bin/env python3
"""与本机独立实现（pycdlib）的目录清单对拍。

    python tools/fixtures/pycdlib_corpus.py   # 先生成映像与基准清单
    python tools/oracle/pycdlib_read.py

对拍内容：每个目录下的 (名字, 是否目录, 大小) 集合，本库 CLI 输出必须与 pycdlib 一致。
"""

import json
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXPECTED = os.path.join(ROOT, "tools", "expected")

# (映像, pycdlib 基准清单)
# (映像, 基准清单, 列目录用的 CLI 子命令)
CASES = [
    ("joliet.iso", "joliet_manifest.json", "ls"),
    ("rockridge.iso", "rockridge_manifest.json", "ls"),
    ("udf.iso", "udf_manifest.json", "udf-ls"),
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


def cli_entries(image, directory, command="ls"):
    out = []
    for line in run_cli([command, image, directory]).splitlines():
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



def ensure_fixtures():
    """缺少对拍映像时先生成：新克隆的仓库不必手工跑生成脚本。"""
    corpus = os.path.join(ROOT, "tools", "corpus")
    missing = [n for n in ["joliet.iso", "rockridge.iso", "boot.iso", "udf.iso"] if not os.path.isfile(os.path.join(corpus, n))]
    if not missing:
        return
    print("缺少对拍映像 %s，先调用生成脚本" % ", ".join(missing))
    for script in ["tools/fixtures/pycdlib_corpus.py", "tools/fixtures/udf_corpus.py"]:
        subprocess.run([sys.executable, os.path.join(ROOT, script)], cwd=ROOT, check=True)

def main():
    ensure_fixtures()
    failures = []
    checked = 0
    for image, manifest_name, command in CASES:
        image_path = "tools/corpus/" + image
        with open(os.path.join(EXPECTED, manifest_name), encoding="utf-8") as f:
            tree = json.load(f)
        for directory, want in sorted(tree.items()):
            path = "/" if directory == "/" else directory
            got = cli_entries(image_path, path, command)
            want_sorted = sorted(want, key=lambda e: e["name"])
            # 只比较基准清单里出现的字段（UDF 清单没有符号链接字段）
            keys = sorted(want_sorted[0]) if want_sorted else []
            got_view = [tuple(e.get(k) for k in keys) for e in got]
            want_view = [tuple(e.get(k) for k in keys) for e in want_sorted]
            if got_view != want_view:
                failures.append(
                    "%s %s 与 pycdlib 不一致:\n  cli     = %s\n  pycdlib = %s"
                    % (image, path, got_view, want_view)
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
