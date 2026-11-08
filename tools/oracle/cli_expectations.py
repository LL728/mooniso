#!/usr/bin/env python3
"""端到端验收：用 CLI 读取仓库内的测试映像，与期望输出逐行/逐字节比对。

    python tools/oracle/cli_expectations.py

加 --mount-point-minimal <dir> 与 --mount-point-files <dir> 时，会把这些
"已挂载的同一映像"的目录内容与 CLI 输出对照 —— 内核实现与本库读同一份字节，
结果必须一致（文件名按本库规则去掉 ;版本号）。
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXPECTED = os.path.join(ROOT, "tools", "expected")

CASES = [
    ("info-minimal", ["info", "tools/corpus/minimal.iso"], "info.txt"),
    ("ls-root", ["ls", "tools/corpus/minimal.iso"], "ls_root.txt"),
    ("ls-sub", ["ls", "tools/corpus/minimal.iso", "/SUB"], "ls_sub.txt"),
    ("info-files", ["info", "tools/corpus/files.iso"], "info_files.txt"),
    ("ls-files", ["ls", "tools/corpus/files.iso"], "ls_files.txt"),
    ("tree-minimal", ["tree", "tools/corpus/minimal.iso"], "tree_minimal.txt"),
    ("verify-minimal", ["verify", "tools/corpus/minimal.iso"], "verify_minimal.txt"),
]

MOUNT_CASES = {
    "minimal": {"entries": {"HELLO.TXT", "SUB"}, "sub_entries": {"INNER.TXT"}},
    "files": {"entries": {"BIG.BIN", "TEXT.TXT", "EMPTY.TXT"}, "sub_entries": set()},
}


def run_cli(args, expect_failure=False):
    cmd = ["moon", "run", "--target", "js", "cmd/main", "--"] + args
    proc = subprocess.run(
        cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    if proc.returncode != 0 and not expect_failure:
        print("CLI 退出码 %d: %s" % (proc.returncode, proc.stderr.strip()))
        sys.exit(2)
    return proc.stdout


def cli_names(args):
    return {line.split("\t")[0] for line in run_cli(args).splitlines() if line}


def strip_version(name):
    """去掉 ISO 9660 的 ;版本号：内核挂载(map=off)保留原始名字，本库对外给出的是去版本号的名字。"""
    return name.split(";")[0]


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest():
    with open(os.path.join(EXPECTED, "files_manifest.json"), encoding="utf-8") as f:
        return json.load(f)


def check_outputs(failures):
    for name, args, expected_file in CASES:
        got = run_cli(args)
        with open(os.path.join(EXPECTED, expected_file), encoding="utf-8") as f:
            want = f.read()
        if got != want:
            failures.append("%s 输出不一致:\n--- got ---\n%s--- want ---\n%s" % (name, got, want))
        else:
            print("ok   %s" % name)


def check_extract(failures):
    manifest = load_manifest()
    tmp = tempfile.mkdtemp(prefix="mooniso-extract-")
    try:
        for name, want in sorted(manifest.items()):
            out = os.path.join(tmp, name)
            run_cli(["extract", "tools/corpus/files.iso", "/" + name, out])
            got_size = os.path.getsize(out)
            got_hash = sha256_file(out)
            if got_size != want["size"] or got_hash != want["sha256"]:
                failures.append(
                    "%s 内容不一致: size %d/%d sha256 %s/%s"
                    % (name, got_size, want["size"], got_hash, want["sha256"])
                )
            else:
                print("ok   extract %s (%d bytes)" % (name, want["size"]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_error_paths(failures):
    # 失败路径现在返回非零退出码（CLI 约定），期望失败的命令要显式声明
    got = run_cli(["ls", "tools/corpus/minimal.iso", "/nope"], expect_failure=True)
    if not got.startswith("ERROR\tno such path"):
        failures.append("缺失路径应报错，实际输出: %r" % got)
    else:
        print("ok   ls-missing-path")
    got = run_cli(
        ["extract", "tools/corpus/minimal.iso", "/SUB", os.devnull],
        expect_failure=True,
    )
    if not got.startswith("ERROR\tis a directory"):
        failures.append("读取目录应报错，实际输出: %r" % got)
    else:
        print("ok   extract-directory-rejected")


def listdir_set(path, failures, normalize=False):
    try:
        names = set(os.listdir(path))
        if normalize:
            names = {strip_version(n) for n in names}
        return names
    except OSError as exc:
        failures.append("无法列出 %s: %s" % (path, exc))
        return None


def check_mount(failures, mounts):
    manifest = load_manifest()
    for key, mount_point in mounts.items():
        if not mount_point:
            continue
        if not os.path.isdir(mount_point):
            failures.append("挂载点不存在: %s" % mount_point)
            continue
        want = MOUNT_CASES[key]
        image = "tools/corpus/%s.iso" % key
        root = listdir_set(mount_point, failures, normalize=True)
        cli_root = cli_names(["ls", image])
        if root is None:
            continue
        if root != want["entries"]:
            failures.append("%s 挂载结果与预期不符: %s" % (key, sorted(root)))
        elif cli_root != root:
            failures.append("%s 根目录不一致: mount=%s cli=%s" % (key, sorted(root), sorted(cli_root)))
        if want["sub_entries"]:
            sub = listdir_set(os.path.join(mount_point, "SUB"), failures, normalize=True)
            cli_sub = cli_names(["ls", image, "/SUB"])
            if sub is not None and (sub != want["sub_entries"] or cli_sub != sub):
                failures.append("%s SUB 目录不一致: mount=%s cli=%s" % (key, sorted(sub), sorted(cli_sub)))
        if key == "files":
            for name, info in sorted(manifest.items()):
                mounted = os.path.join(mount_point, name)
                if sha256_file(mounted) != info["sha256"]:
                    failures.append("%s 挂载内容与生成器不一致" % name)
                else:
                    print("ok   mount %s bytes match (%s)" % (name, mount_point))
        print("ok   mount-vs-cli %s (%s)" % (key, mount_point))


def main():
    failures = []
    check_outputs(failures)
    check_extract(failures)
    check_error_paths(failures)
    mounts = {"minimal": None, "files": None}
    argv = sys.argv[1:]
    for i, arg in enumerate(argv):
        if arg == "--mount-point-minimal" and i + 1 < len(argv):
            mounts["minimal"] = argv[i + 1]
        if arg == "--mount-point-files" and i + 1 < len(argv):
            mounts["files"] = argv[i + 1]
    check_mount(failures, mounts)
    if failures:
        print("\n".join(failures))
        print("FAILED")
        sys.exit(1)
    print("ALL PASS")


if __name__ == "__main__":
    main()
