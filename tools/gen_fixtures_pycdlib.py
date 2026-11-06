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


def strip_version(name):
    return name.split(";")[0]


def dump_manifest(iso_path, out_path):
    iso = pycdlib.PyCdlib()
    iso.open(iso_path)
    try:
        tree = {}

        def walk(jpath, rel):
            entries = []
            for child in iso.list_children(joliet_path=jpath):
                raw = child.file_identifier()
                name = strip_version(raw.decode("utf-16_be"))
                if name in (".", ".."):
                    continue
                entries.append(
                    {"name": name, "size": child.data_length, "is_dir": child.is_dir()}
                )
                if child.is_dir():
                    walk(jpath.rstrip("/") + "/" + name, rel.rstrip("/") + "/" + name)
            tree[rel] = sorted(entries, key=lambda e: e["name"])

        walk("/", "/")
        with open(out_path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(tree, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
        return tree
    finally:
        iso.close()


def main():
    os.makedirs(CORPUS, exist_ok=True)
    os.makedirs(EXPECTED, exist_ok=True)
    joliet = os.path.join(CORPUS, "joliet.iso")
    build_joliet(joliet)
    tree = dump_manifest(joliet, os.path.join(EXPECTED, "joliet_manifest.json"))
    print("wrote %s (%d bytes)" % (joliet, os.path.getsize(joliet)))
    print("manifest dirs: %s" % ", ".join(sorted(tree)))


if __name__ == "__main__":
    main()
