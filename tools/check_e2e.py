#!/usr/bin/env python3
"""端到端验收：用 CLI 读取仓库内的测试映像，与期望输出逐行比对。

    python tools/check_e2e.py

加 --mount-point <dir> 时，会把这个"已挂载的同一映像"的目录内容
与 CLI 输出对照 —— 两种独立实现读同一份字节，结果必须一致。
挂载动作由调用方完成（CI 用内核 iso9660，本地可用系统自带的镜像挂载）。
"""

import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXPECTED = os.path.join(ROOT, "tools", "expected")

CASES = [
    ("info", ["info", "tools/corpus/minimal.iso"], "info.txt"),
    ("ls-root", ["ls", "tools/corpus/minimal.iso"], "ls_root.txt"),
    ("ls-sub", ["ls", "tools/corpus/minimal.iso", "/SUB"], "ls_sub.txt"),
]

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


def cli_names(args):
    return {line.split("\t")[0] for line in run_cli(args).splitlines() if line}


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


def check_mount(failures, mount_point):
    if not os.path.isdir(mount_point):
        failures.append("挂载点不存在: %s" % mount_point)
        return
    root = set(os.listdir(mount_point))
    sub = set(os.listdir(os.path.join(mount_point, "SUB")))
    cli_root = cli_names(["ls", "tools/corpus/minimal.iso"])
    cli_sub = cli_names(["ls", "tools/corpus/minimal.iso", "/SUB"])
    if root != MOUNT_ENTRIES:
        failures.append("挂载结果与预期不符: %s" % sorted(root))
    elif cli_root != root:
        failures.append("根目录不一致: mount=%s cli=%s" % (sorted(root), sorted(cli_root)))
    if sub != MOUNT_SUB_ENTRIES:
        failures.append("挂载的 SUB 目录与预期不符: %s" % sorted(sub))
    elif cli_sub != sub:
        failures.append("SUB 目录不一致: mount=%s cli=%s" % (sorted(sub), sorted(cli_sub)))
    if not failures:
        print("ok   mount-vs-cli (%s)" % mount_point)


def main():
    failures = []
    check_outputs(failures)
    check_error_path(failures)
    mount_point = None
    for i, arg in enumerate(sys.argv):
        if arg == "--mount-point" and i + 1 < len(sys.argv):
            mount_point = sys.argv[i + 1]
    if mount_point:
        check_mount(failures, mount_point)
    if failures:
        print("\n".join(failures))
        print("FAILED")
        sys.exit(1)
    print("ALL PASS")


if __name__ == "__main__":
    main()
