#!/usr/bin/env python3
"""写入侧验收：用本库把目录打包成 ISO，再用独立实现读回比对。

    python tools/check_roundtrip.py [--mount-point DIR]

1) 始终做：pycdlib（独立实现）打开生成的映像，逐条比对名字/类型/大小；
2) 可选：把已挂载的同一映像与源目录逐文件比对 sha256（--mount-point）。
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

import pycdlib

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SAMPLE_FILES = {
    "hello.txt": b"hello roundtrip\n",
    "empty.bin": b"",
    "big.bin": bytes((i * 31 + 7) % 256 for i in range(5000)),
    "Docs/note.md": "# note\n\n一批说明\n".encode("utf-8"),
    "Docs/说明.txt": "中文内容\n".encode("utf-8"),
    "Docs/deep/nested.dat": bytes(range(256)) * 3,
    "a-very-long-file-name-that-level-1-cannot-hold.txt": b"long name\n",
}


def build_source(tmp):
    for rel, data in SAMPLE_FILES.items():
        path = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
    return tmp


def run_cli(args):
    cmd = ["moon", "run", "--target", "js", "cmd/main", "--"] + args
    proc = subprocess.run(
        cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    if proc.returncode != 0:
        print("CLI 退出码 %d: %s" % (proc.returncode, proc.stderr.strip()))
        sys.exit(2)
    return proc.stdout


def strip_version(name):
    return name.split(";")[0]


def listing_of(iso):
    """pycdlib 的 Joliet 视角：{相对路径: (是否目录, 大小)}。"""
    out = {}

    def recurse(jpath, rel):
        for child in iso.list_children(joliet_path=jpath):
            name = strip_version(child.file_identifier().decode("utf-16_be"))
            if name in (".", ".."):
                continue
            child_rel = (rel + "/" + name) if rel else name
            if child.is_dir():
                out[child_rel] = (True, child.data_length)
                recurse(jpath.rstrip("/") + "/" + name, child_rel)
            else:
                out[child_rel] = (False, child.data_length)

    recurse("/", "")
    return out


def expected_listing():
    out = {}
    for rel, data in SAMPLE_FILES.items():
        parts = rel.split("/")
        for i in range(1, len(parts)):
            out["/".join(parts[:i])] = (True, 2048)
        out[rel] = (False, len(data))
    return out


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compare_mount(failures, mount_point, src_dir):
    if not os.path.isdir(mount_point):
        failures.append("挂载点不存在: %s" % mount_point)
        return
    for rel, data in sorted(SAMPLE_FILES.items()):
        mounted = os.path.join(mount_point, rel.replace("/", os.sep))
        if not os.path.isfile(mounted):
            failures.append("挂载后缺少文件: %s" % rel)
            continue
        want = hashlib.sha256(data).hexdigest()
        got = sha256_file(mounted)
        if got != want:
            failures.append("文件内容不一致 %s: %s != %s" % (rel, got, want))
    if not failures:
        print("ok   挂载后与源目录逐文件一致（%d 个文件）" % len(SAMPLE_FILES))


def check_symlink(failures):
    """写入侧：生成带 Rock Ridge 符号链接的映像，用 pycdlib 校验链接目标。"""
    tmp = tempfile.mkdtemp(prefix="mooniso-link-")
    try:
        with open(os.path.join(tmp, "hello.txt"), "wb") as f:
            f.write(b"hi\n")
        image = os.path.join(tmp, "link.iso")
        run_cli(["create", image, tmp, "--link", "/link.txt=/hello.txt"])
        iso = pycdlib.PyCdlib()
        iso.open(image)
        try:
            found = False
            for child in iso.list_children(rr_path="/"):
                rr = child.rock_ridge
                name = rr.name() if rr else None
                if name == "link.txt":
                    found = True
                    if not child.is_symlink():
                        failures.append("link.txt 未被识别为符号链接")
                    elif rr.symlink_path() != "/hello.txt":
                        failures.append("link.txt 目标不符: %r" % rr.symlink_path())
            if found and not failures:
                print("ok   Rock Ridge 符号链接被试独立实现识别")
        finally:
            iso.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_bootable(failures):
    """写入侧：生成可启动 ISO，用 pycdlib 校验 El Torito 启动项。"""
    tmp = tempfile.mkdtemp(prefix="mooniso-boot-")
    try:
        with open(os.path.join(tmp, "boot.bin"), "wb") as f:
            f.write(bytes(4096))
        with open(os.path.join(tmp, "hello.txt"), "wb") as f:
            f.write(b"bootable\n")
        image = os.path.join(tmp, "boot.iso")
        run_cli(["create", image, tmp, "--boot", "/boot.bin"])
        with open(os.path.join(tmp, "efi.img"), "wb") as f:
            f.write(bytes(4096))
        dual = os.path.join(tmp, "dual.iso")
        run_cli(["create", dual, tmp, "--boot", "/boot.bin", "--efi", "/efi.img"])
        iso = pycdlib.PyCdlib()
        iso.open(dual)
        try:
            catalog = iso.eltorito_boot_catalog
            sections = catalog.sections
            efi_ok = (
                len(sections) == 1
                and sections[0].platform_id == 0xEF
                and len(sections[0].section_entries) == 1
                and sections[0].section_entries[0].boot_indicator == 0x88
            )
            if not efi_ok:
                failures.append("UEFI section header 与期望不符: sections=%d" % len(sections))
            else:
                print("ok   UEFI section header（平台 0xEF）被试独立实现识别")
        finally:
            iso.close()
        iso = pycdlib.PyCdlib()
        iso.open(image)
        try:
            catalog = iso.eltorito_boot_catalog
            entry = catalog.initial_entry
            record = iso.get_record(iso_path="/BOOT.BIN;1")
            checks = {
                "platform_id": (catalog.validation_entry.platform_id, 0),
                "boot_indicator": (entry.boot_indicator, 0x88),
                "media_type": (entry.boot_media_type, 0),
                "sector_count": (entry.sector_count, 4),
                "load_rba": (entry.load_rba, record.extent_location()),
                "joliet": (iso.has_joliet(), True),
            }
            bad = {k: v for k, v in checks.items() if v[0] != v[1]}
            if bad:
                failures.append("启动项与期望不符: %s" % bad)
            else:
                print("ok   可启动映像的 El Torito 启动项与 pycdlib 一致")
        finally:
            iso.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def mount_only(mount_point, src_dir):
    """--verify-mount <mnt> <src>：仅比对已挂载映像与源目录（供本地/CI 分步调用）。"""
    failures = []
    compare_mount(failures, mount_point, src_dir)
    if failures:
        print("\n".join(failures))
        print("FAILED")
        sys.exit(1)
    print("ALL PASS")


def main():
    failures = []
    args = sys.argv[1:]
    if args and args[0] == "--verify-mount":
        if len(args) < 3:
            print("用法: check_roundtrip.py --verify-mount <挂载点> <源目录>")
            sys.exit(2)
        mount_only(args[1], args[2])
        return
    if args and args[0] == "--boot-only":
        failures = []
        check_bootable(failures)
        check_symlink(failures)
        if failures:
            print("\n".join(failures))
            print("FAILED")
            sys.exit(1)
        print("ALL PASS")
        return
    mount_point = None
    workdir = None
    for i, arg in enumerate(args):
        if arg == "--mount-point" and i + 1 < len(args):
            mount_point = args[i + 1]
        if arg == "--workdir" and i + 1 < len(args):
            workdir = args[i + 1]
    tmp = workdir or tempfile.mkdtemp(prefix="mooniso-roundtrip-")
    os.makedirs(tmp, exist_ok=True)
    try:
        src = build_source(os.path.join(tmp, "src"))
        image = os.path.join(tmp, "out.iso")
        run_cli(["create", image, src])
        print("ok   created %s (%d bytes)" % (os.path.basename(image), os.path.getsize(image)))
        iso = pycdlib.PyCdlib()
        iso.open(image)
        try:
            got = listing_of(iso)
        finally:
            iso.close()
        want = expected_listing()
        for rel in sorted(set(got) | set(want)):
            if got.get(rel) != want.get(rel):
                failures.append("条目不一致 %s: 生成=%s 期望=%s" % (rel, got.get(rel), want.get(rel)))
        if not failures:
            print("ok   pycdlib 读回的目录树一致（%d 个条目）" % len(want))
        check_bootable(failures)
        if mount_point:
            compare_mount(failures, mount_point, src)
        # 生成物留在 %TEMP%，方便 --mount-point 调用方挂载前使用
        if mount_point or workdir:
            print("image=%s" % image)
            print("src=%s" % src)
    finally:
        if not mount_point and not workdir:
            shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        print("\n".join(failures))
        print("FAILED")
        sys.exit(1)
    print("ALL PASS")


if __name__ == "__main__":
    main()
