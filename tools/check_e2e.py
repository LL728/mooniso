#!/usr/bin/env python3
"""端到端验收：用 CLI 读取仓库内的测试映像，与期望输出逐行比对。

    python tools/check_e2e.py

在 Linux（CI）上加 --mount 时，会额外用内核 iso9660 驱动挂载同一映像，
把挂载结果与 CLI 的目录输出独立对照 —— 两种实现读同一份字节，结果必须一致。
"""

import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(ROOT, "tools", "corpus")
EXPECTED = os.path.join(ROOT, "tools", "expected")

CASES = [
    ("info", ["info", "tools/corpus/minimal.iso"], "info.txt"),
    ("ls-root", ["ls", "tools/corpus/minimal.iso"], "ls_root.txt"),
    ("ls-sub", ["ls", "tools/corpus/minimal.iso", "/SUB"], "ls_sub.txt"),
]

# 挂载结果里的相对路径 -> CLI 目录输出里的条目名
MOUNT_ENTRIES = {"HELLO.TXT", "SUB"}
MOUNT_SUB_ENTRIES = {"INNER.TXT"}


def run_cli(args):
    cmd = ["moon", "run", "--target", "js", "cmd/main", "--"] + args
    proc = subprocess.run(
        cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    if proc.returncode != 0:
        print("CLI 退出码 %d: %s" % (proc.returncode, proc.stderr.strip()))
        sys.exit(2)
    return proc.stdout


def check_outputs(failures):
    for name, args, expected_file in CASES:
        got = run_cli(args)
        with open(os.path.join(EXPECTED, expected_file), encoding="utf-8") as f:
            want = f.read()
        if got != want:
            failures.append("%s 输出不一致:\n--- got ---\n%s--- want ---\n%s" % (name, got, want))
        else:
            print("ok   %s" % name)


def check_error_path(failures):
    got = run_cli(["ls", "tools/corpus/minimal.iso", "/nope"])
    if not got.startswith("ERROR\tno such path"):
        failures.append("缺失路径应报错，实际输出: %r" % got)
    else:
        print("ok   ls-missing-path")


def check_mount(failures):
    image = os.path.join(CORPUS, "minimal.iso")
    mnt = "/tmp/mooniso-mnt"
    os.makedirs(mnt, exist_ok=True)
    if subprocess.run(["mount", "-o", "loop,ro", "-t", "iso9660", image, mnt]).returncode != 0:
        failures.append("挂载失败（需要 root）")
        return
    try:
        root = set(os.listdir(mnt))
        sub = set(os.listdir(os.path.join(mnt, "SUB")))
        cli_root = {line.split("\t")[0] for line in run_cli(["ls", "tools/corpus/minimal.iso"]).splitlines()}
        cli_sub = {
            line.split("\t")[0]
            for line in run_cli(["ls", "tools/corpus/minimal.iso", "/SUB"]).splitlines()
        }
        if root != MOUNT_ENTRIES or cli_root != root:
            failures.append("根目录不一致: mount=%s cli=%s" % (sorted(root), sorted(cli_root)))
        if sub != MOUNT_SUB_ENTRIES or cli_sub != sub:
            failures.append("SUB 目录不一致: mount=%s cli=%s" % (sorted(sub), sorted(cli_sub)))
        if not failures:
            print("ok   mount-vs-cli")
    finally:
        subprocess.run(["umount", mnt], check=False)


def main():
    failures = []
    check_outputs(failures)
    check_error_path(failures)
    if "--mount" in sys.argv:
        check_mount(failures)
    if failures:
        print("\n".join(failures))
        print("FAILED")
        sys.exit(1)
    print("ALL PASS")


if __name__ == "__main__":
    main()
