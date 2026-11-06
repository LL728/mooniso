#!/usr/bin/env python3
"""用 pycdlib（独立实现）生成测试映像，并导出它的目录清单作为对拍基准。

    python tools/gen_fixtures_pycdlib.py

产物：
    tools/corpus/joliet.iso          Joliet（UCS-2）名字的映像
    tools/expected/joliet_manifest.json   pycdlib 自己列出的目录树

manifest 的 name 已去掉 ;版本号，与本库对外行为一致。
"""

import io
import json
import os
import sys

import pycdlib

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
EXPECTED = os.path.join(HERE, "expected")

README_TEXT = "joliet fixture\n"


def build_joliet(path):
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, joliet=3, vol_ident="MOONISO_JOLIET")
    data = README_TEXT.encode("utf-8")
    iso.add_fp(io.BytesIO(data), len(data), "/HELLO.TXT;1", joliet_path="/Hello.txt")
    iso.add_directory("/DOCS", joliet_path="/资料")
    inner = ("说明内容\n").encode("utf-8")
    iso.add_fp(
        io.BytesIO(inner),
        len(inner),
        "/DOCS/NOTE.TXT;1",
        joliet_path="/资料/说明.txt",
    )
    long_name = "a" * 60 + ".txt"
    iso.add_fp(
        io.BytesIO(b"long\n"),
        5,
        "/DOCS/LONG.TXT;1",
        joliet_path="/资料/" + long_name,
    )
    iso.write(path)
    iso.close()


def build_rock_ridge(path):
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, rock_ridge="1.09", vol_ident="MOONISO_RR")
    data = b"rock ridge fixture\n"
    iso.add_fp(io.BytesIO(data), len(data), "/HELLO.TXT;1", rr_name="Hello.txt")
    iso.add_directory("/DOCS", rr_name="Docs")
    inner = b"deep note\n"
    iso.add_fp(io.BytesIO(inner), len(inner), "/DOCS/NOTE.TXT;1", rr_name="Note.txt")
    # rr_symlink_name 是链接自身的名字，rr_path 是它指向的目标
    iso.add_symlink("/DOCS/LINK.;1", rr_symlink_name="link", rr_path="/Hello.txt")
    iso.write(path)
    iso.close()


def build_boot(path):
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, vol_ident="MOONISO_BOOT")
    kernel = bytes(2048)
    iso.add_fp(io.BytesIO(kernel), len(kernel), "/BOOT.BIN;1")
    iso.add_eltorito("/BOOT.BIN;1", boot_load_size=4, platform_id=0)
    iso.write(path)
    iso.close()


def strip_version(name):
    if isinstance(name, bytes):
        name = name.decode("ascii", "replace")
    return name.split(";")[0]


def dump_manifest(iso_path, out_path, namespace="joliet"):
    """namespace: joliet 用 UCS-2 名字；rockridge 用 RR 替代名字。"""
    iso = pycdlib.PyCdlib()
    iso.open(iso_path)
    try:
        tree = {}
        key = "joliet_path" if namespace == "joliet" else "rr_path"

        def child_name(child):
            if namespace == "joliet":
                return strip_version(child.file_identifier().decode("utf-16_be"))
            rr = child.rock_ridge
            if rr is not None and rr.name() is not None:
                return strip_version(rr.name())
            return strip_version(child.file_identifier().decode("ascii"))

        def walk(path, rel):
            entries = []
            for child in iso.list_children(**{key: path}):
                name = child_name(child)
                if name in (".", ".."):
                    continue
                entries.append(
                    {
                        "name": name,
                        "size": child.data_length,
                        "is_dir": child.is_dir(),
                        "is_symlink": child.is_symlink(),
                    }
                )
                if child.is_dir():
                    walk(path.rstrip("/") + "/" + name, rel.rstrip("/") + "/" + name)
            tree[rel] = sorted(entries, key=lambda e: e["name"])

        walk("/", "/")
        with open(out_path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(tree, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
        return tree
    finally:
        iso.close()


def dump_boot_manifest(iso_path, out_path):
    """用 pycdlib 自己的 El Torito 解析结果作为启动项基准。"""
    iso = pycdlib.PyCdlib()
    iso.open(iso_path)
    try:
        catalog = iso.eltorito_boot_catalog
        entry = catalog.initial_entry
        manifest = {
            "platform_id": catalog.validation_entry.platform_id,
            "bootable": entry.boot_indicator == 0x88,
            "media_type": entry.boot_media_type,
            "sector_count": entry.sector_count,
            "load_lba": entry.load_rba,
        }
        with open(out_path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
            f.write("\n")
        return manifest
    finally:
        iso.close()


def main():
    os.makedirs(CORPUS, exist_ok=True)
    os.makedirs(EXPECTED, exist_ok=True)
    joliet = os.path.join(CORPUS, "joliet.iso")
    build_joliet(joliet)
    tree = dump_manifest(joliet, os.path.join(EXPECTED, "joliet_manifest.json"), "joliet")
    print("wrote %s (%d bytes)" % (joliet, os.path.getsize(joliet)))
    print("joliet manifest dirs: %s" % ", ".join(sorted(tree)))

    rr = os.path.join(CORPUS, "rockridge.iso")
    build_rock_ridge(rr)
    tree = dump_manifest(rr, os.path.join(EXPECTED, "rockridge_manifest.json"), "rockridge")
    print("wrote %s (%d bytes)" % (rr, os.path.getsize(rr)))
    print("rockridge manifest dirs: %s" % ", ".join(sorted(tree)))

    boot = os.path.join(CORPUS, "boot.iso")
    build_boot(boot)
    dump_boot_manifest(boot, os.path.join(EXPECTED, "boot_manifest.json"))
    print("wrote %s (%d bytes)" % (boot, os.path.getsize(boot)))


if __name__ == "__main__":
    main()
