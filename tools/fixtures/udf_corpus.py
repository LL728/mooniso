#!/usr/bin/env python3
"""用 pycdlib 生成 UDF 测试映像，并导出它的目录清单作为对拍基准。

    python tools/fixtures/udf_corpus.py

产物：
    tools/corpus/udf.iso             ISO 9660 + UDF 2.60 双格式映像
    tools/expected/udf_manifest.json pycdlib 自己走 UDF 视角列出的目录树
"""

import io
import json
import os
import sys

import pycdlib

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(HERE, "corpus")
EXPECTED = os.path.join(HERE, "expected")

# (ISO 路径, UDF 路径, 内容)：ISO 名字受 8.3 限制，UDF 名字保留原名
FILES = [
    ("/HELLO.TXT;1", "/hello.txt", b"hello udf\n"),
    ("/DOCS/NOTE.MD;1", "/Docs/note.md", b"# udf note\n"),
    ("/DOCS/CN.TXT;1", "/Docs/\u8bf4\u660e.txt", "\u4e2d\u6587 udf\n".encode("utf-8")),
]


def build(path):
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, udf="2.60", vol_ident="MOONISO_UDF")
    iso.add_directory("/DOCS", udf_path="/Docs")
    for iso_path, udf_path, data in FILES:
        iso.add_fp(io.BytesIO(data), len(data), iso_path, udf_path=udf_path)
    iso.write(path)
    iso.close()


def decode_udf_name(raw):
    """pycdlib 返回的名字已去掉压缩标识：ASCII 是 Latin-1，中文是 UTF-16BE。"""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        pass
    try:
        return raw.decode("utf-16_be")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def listing(path):
    iso = pycdlib.PyCdlib()
    iso.open(path)
    try:
        tree = {}

        def walk(udf_path, rel):
            entries = []
            for child in iso.list_children(udf_path=udf_path):
                name = decode_udf_name(child.file_identifier())
                if name in (".", ".."):
                    continue
                entries.append(
                    {"name": name, "is_dir": child.is_dir(), "size": child.get_data_length()}
                )
                if child.is_dir():
                    walk(udf_path.rstrip("/") + "/" + name, rel.rstrip("/") + "/" + name)
            tree[rel] = sorted(entries, key=lambda e: e["name"])

        walk("/", "/")
        return tree
    finally:
        iso.close()


def main():
    os.makedirs(CORPUS, exist_ok=True)
    os.makedirs(EXPECTED, exist_ok=True)
    path = os.path.join(CORPUS, "udf.iso")
    build(path)
    tree = listing(path)
    with open(os.path.join(EXPECTED, "udf_manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(tree, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print("wrote %s (%d bytes)" % (path, os.path.getsize(path)))
    print("udf manifest dirs: %s" % ", ".join(sorted(tree)))


if __name__ == "__main__":
    main()
