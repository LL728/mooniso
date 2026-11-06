#!/usr/bin/env python3
"""生成 ISO 9660 测试映像（ECMA-119）。

只依赖标准库，产物是可复现的字节序列：
    python tools/gen_fixtures.py

映像布局（逻辑块 2048 字节）：
    LBA 0-15   系统区（全零）
    LBA 16     主卷描述符（PVD）
    LBA 17     卷描述符结束符
    LBA 18     L 路径表（小端）
    LBA 19     M 路径表（大端）
    LBA 20     根目录
    LBA 21     SUB 子目录
    LBA 22     HELLO.TXT 内容
    LBA 23     SUB/INNER.TXT 内容
"""

import hashlib
import json
import os
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8")

SECTOR = 2048
ROOT_LBA = 20
SUB_LBA = 21
HELLO_LBA = 22
INNER_LBA = 23
TOTAL_SECTORS = 24

HELLO = b"Hello, ISO 9660!\n"
INNER = b"inner file\n"

# 2026-01-02 03:04:05 UTC（年字段 = 年份 - 1900）
DATE7 = bytes([126, 1, 2, 3, 4, 5, 0])


def both16(value):
    return struct.pack("<H", value) + struct.pack(">H", value)


def both32(value):
    return struct.pack("<I", value) + struct.pack(">I", value)


def dir_record(extent, size, name, is_dir):
    flags = 2 if is_dir else 0
    rec = bytearray()
    rec += b"\x00"                 # 记录长度（最后回填）
    rec += b"\x00"                 # 扩展属性长度
    rec += both32(extent)
    rec += both32(size)
    rec += DATE7
    rec += bytes([flags])
    rec += b"\x00"                 # 文件单元大小
    rec += b"\x00"                 # 交错间隔
    rec += both16(1)               # 卷序号
    rec += bytes([len(name)])
    rec += name
    if len(name) % 2 == 0:
        rec += b"\x00"
    rec[0] = len(rec)
    return bytes(rec)


def directory_data(entries, parent_dir):
    """entries: [(extent, size, name_bytes, is_dir)]，会自动加入 . 与 .."""
    records = [
        dir_record(ROOT_LBA if parent_dir == "self" else 0, 0, b"\x00", True),
    ]
    return records


def pack_directory(self_lba, parent_lba, entries):
    """按扇区规则打包目录记录：记录不得跨越扇区边界。"""
    out = bytearray()
    recs = [dir_record(self_lba, 0, b"\x00", True), dir_record(parent_lba, 0, b"\x01", True)]
    recs += [dir_record(e[0], e[1], e[2], e[3]) for e in entries]
    for rec in recs:
        if len(out) % SECTOR + len(rec) > SECTOR:
            out += b"\x00" * (SECTOR - len(out) % SECTOR)
        out += rec
    if len(out) % SECTOR:
        out += b"\x00" * (SECTOR - len(out) % SECTOR)
    size = len(out)
    # 回填 . 与 .. 的数据长度
    for i, lba in enumerate((self_lba, parent_lba)):
        pass
    return bytes(out), size


def path_table(entries, little):
    fmt = "<" if little else ">"
    out = bytearray()
    for name, extent, parent in entries:
        rec = bytearray()
        rec += bytes([len(name)])
        rec += b"\x00"
        rec += struct.pack(fmt + "I", extent)
        rec += struct.pack(fmt + "H", parent)
        rec += name
        if len(rec) % 2:
            rec += b"\x00"
        out += rec
    return bytes(out)


def build():
    image = bytearray(SECTOR * TOTAL_SECTORS)

    root_data, root_size = pack_directory(
        ROOT_LBA, ROOT_LBA,
        [
            (HELLO_LBA, len(HELLO), b"HELLO.TXT;1", False),
            (SUB_LBA, SECTOR, b"SUB", True),
        ],
    )
    sub_data, sub_size = pack_directory(SUB_LBA, ROOT_LBA, [(INNER_LBA, len(INNER), b"INNER.TXT;1", False)])

    # 目录记录里的数据长度要覆盖自身扇区
    root_data, root_size = patch_dir_self_size(root_data, ROOT_LBA, root_size)
    sub_data, sub_size = patch_dir_self_size(sub_data, SUB_LBA, sub_size)

    image[ROOT_LBA * SECTOR:ROOT_LBA * SECTOR + len(root_data)] = root_data
    image[SUB_LBA * SECTOR:SUB_LBA * SECTOR + len(sub_data)] = sub_data
    image[HELLO_LBA * SECTOR:HELLO_LBA * SECTOR + len(HELLO)] = HELLO
    image[INNER_LBA * SECTOR:INNER_LBA * SECTOR + len(INNER)] = INNER

    # 路径表必须列出所有目录，否则部分实现（如 Windows CDFS）无法解析子目录
    tree = [(b"\x00", ROOT_LBA, 1), (b"SUB", SUB_LBA, 1)]
    l_table = path_table(tree, True)
    m_table = path_table(tree, False)
    image[18 * SECTOR:18 * SECTOR + len(l_table)] = l_table
    image[19 * SECTOR:19 * SECTOR + len(m_table)] = m_table

    pvd = bytearray(SECTOR)
    pvd[0] = 1
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[8:40] = b" " * 32                              # 系统标识
    pvd[40:72] = b"MOONISO_TEST".ljust(32, b" ")        # 卷标识
    pvd[80:88] = both32(TOTAL_SECTORS)
    pvd[120:124] = both16(1)                            # 卷集大小
    pvd[124:128] = both16(1)                            # 卷序号
    pvd[128:132] = both16(SECTOR)                       # 逻辑块大小
    pvd[132:140] = both32(len(l_table))                 # 路径表大小
    pvd[140:144] = struct.pack("<I", 18)                # L 路径表位置
    pvd[148:152] = struct.pack(">I", 19)                # M 路径表位置
    root_rec = dir_record(ROOT_LBA, root_size, b"\x00", True)
    pvd[156:156 + len(root_rec)] = root_rec
    pvd[190:318] = b" " * 128                           # 卷集标识
    pvd[318:446] = b" " * 128                           # 出版者
    pvd[446:574] = b" " * 128                           # 数据准备者
    pvd[574:702] = b" " * 128                           # 应用标识
    pvd[702:739] = b" " * 37
    pvd[739:776] = b" " * 37
    pvd[776:813] = b" " * 37
    for off in (813, 830, 847, 864):
        pvd[off:off + 17] = b"0" * 16 + b"\x00"         # 日期字段（占位）
    pvd[881] = 1                                        # 文件结构版本
    image[16 * SECTOR:17 * SECTOR] = pvd

    term = bytearray(SECTOR)
    term[0] = 255
    term[1:6] = b"CD001"
    term[6] = 1
    image[17 * SECTOR:18 * SECTOR] = term

    return bytes(image)


def patch_dir_self_size(data, self_lba, size):
    """把 . 与 .. 记录的数据长度改成该目录实际占用的扇区数。"""
    out = bytearray(data)
    pos = 0
    for _ in range(2):
        rec_len = out[pos]
        out[pos + 10:pos + 18] = both32(size)
        pos += rec_len
    return bytes(out), size




# ---------------------------------------------------------------------------
# files.iso：覆盖文件内容读取的边界（多段文件、空文件、含换行文本）
# ---------------------------------------------------------------------------

BIG_SIZE = 5000
BIG = bytes((i * 7 + 3) % 256 for i in range(BIG_SIZE))
TEXT = b"line one\nline two\n"
EMPTY = b""


def build_files(multi_extent=True):
    """根目录三个文件；BIG.BIN 可选拆成 3 个连续记录（多段文件）。"""
    root_lba = 20
    cursor = 21

    if multi_extent:
        parts = [(cursor, 2048), (cursor + 1, 2048), (cursor + 2, BIG_SIZE - 4096)]
        cursor += 3
    else:
        parts = [(cursor, BIG_SIZE)]
        cursor += (BIG_SIZE + SECTOR - 1) // SECTOR
    text_lba = cursor
    cursor += 1
    empty_lba = cursor
    cursor += 1
    total = cursor

    entries = []
    for index, (lba, size) in enumerate(parts):
        # 多段文件：除最后一段外，flags 的 bit 7 置位
        flags = 0x80 if (multi_extent and index < len(parts) - 1) else 0x00
        entries.append((lba, size, b"BIG.BIN;1", False, flags))
    entries.append((text_lba, len(TEXT), b"TEXT.TXT;1", False, 0x00))
    entries.append((empty_lba, len(EMPTY), b"EMPTY.TXT;1", False, 0x00))

    root_data, root_size = pack_directory_flagged(root_lba, root_lba, entries)

    image = bytearray(SECTOR * total)
    image[root_lba * SECTOR:root_lba * SECTOR + len(root_data)] = root_data
    for lba, size in parts:
        offset = (lba - parts[0][0]) * SECTOR
        image[lba * SECTOR:lba * SECTOR + size] = BIG[offset:offset + size]
    image[text_lba * SECTOR:text_lba * SECTOR + len(TEXT)] = TEXT

    tree = [(b"\x00", root_lba, 1)]
    l_table = path_table(tree, True)
    m_table = path_table(tree, False)
    image[18 * SECTOR:18 * SECTOR + len(l_table)] = l_table
    image[19 * SECTOR:19 * SECTOR + len(m_table)] = m_table

    pvd = make_pvd(total, root_lba, root_size, len(l_table))
    image[16 * SECTOR:17 * SECTOR] = pvd
    image[17 * SECTOR:18 * SECTOR] = make_terminator()
    return bytes(image)


def make_pvd(total_sectors, root_lba, root_size, table_size):
    pvd = bytearray(SECTOR)
    pvd[0] = 1
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[8:40] = b" " * 32
    pvd[40:72] = b"MOONISO_TEST".ljust(32, b" ")
    pvd[80:88] = both32(total_sectors)
    pvd[120:124] = both16(1)
    pvd[124:128] = both16(1)
    pvd[128:132] = both16(SECTOR)
    pvd[132:140] = both32(table_size)
    pvd[140:144] = struct.pack("<I", 18)
    pvd[148:152] = struct.pack(">I", 19)
    root_rec = dir_record(root_lba, root_size, b"\x00", True)
    pvd[156:156 + len(root_rec)] = root_rec
    pvd[190:318] = b" " * 128
    pvd[318:446] = b" " * 128
    pvd[446:574] = b" " * 128
    pvd[574:702] = b" " * 128
    pvd[702:739] = b" " * 37
    pvd[739:776] = b" " * 37
    pvd[776:813] = b" " * 37
    for off in (813, 830, 847, 864):
        pvd[off:off + 17] = b"0" * 16 + b"\x00"
    pvd[881] = 1
    return pvd


def make_terminator():
    term = bytearray(SECTOR)
    term[0] = 255
    term[1:6] = b"CD001"
    term[6] = 1
    return term


def pack_directory_flagged(self_lba, parent_lba, entries):
    """entries: (extent, size, name, is_dir, flags_extra)"""
    out = bytearray()
    recs = [dir_record(self_lba, 0, b"\x00", True), dir_record(parent_lba, 0, b"\x01", True)]
    for extent, size, name, is_dir, extra in entries:
        rec = bytearray(dir_record(extent, size, name, is_dir))
        rec[25] = rec[25] | extra
        recs.append(bytes(rec))
    for rec in recs:
        if len(out) % SECTOR + len(rec) > SECTOR:
            out += b"\x00" * (SECTOR - len(out) % SECTOR)
        out += rec
    if len(out) % SECTOR:
        out += b"\x00" * (SECTOR - len(out) % SECTOR)
    size = len(out)
    out2 = bytearray(out)
    pos = 0
    for _ in range(2):
        rec_len = out2[pos]
        out2[pos + 10:pos + 18] = both32(size)
        pos += rec_len
    return bytes(out2), size


def write_expected():
    """期望输出：CLI 逐行输出与文件内容的 sha256 清单，供对拍脚本使用。"""
    exp_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "expected")
    os.makedirs(exp_dir, exist_ok=True)
    stamp = "2026-01-02T03:04:05"
    listing = "".join(
        "%s\tfile\t%d\t%s\n" % (name, size, stamp)
        for name, size in (("BIG.BIN", BIG_SIZE), ("TEXT.TXT", len(TEXT)), ("EMPTY.TXT", 0))
    )
    with open(os.path.join(exp_dir, "ls_files.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(listing)
    with open(os.path.join(exp_dir, "info_files.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(
            "volume_id=MOONISO_TEST\nblock_size=2048\nvolume_space_size=26\n"
            "root_extent=20\nroot_size=2048\n"
        )
    manifest = {
        "BIG.BIN": {"size": BIG_SIZE, "sha256": hashlib.sha256(BIG).hexdigest()},
        "TEXT.TXT": {"size": len(TEXT), "sha256": hashlib.sha256(TEXT).hexdigest()},
        "EMPTY.TXT": {"size": 0, "sha256": hashlib.sha256(EMPTY).hexdigest()},
    }
    with open(os.path.join(exp_dir, "files_manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")


def main():
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus")
    os.makedirs(out_dir, exist_ok=True)
    for name, data in (
        ("minimal.iso", build()),
        ("files.iso", build_files(multi_extent=True)),
    ):
        path = os.path.join(out_dir, name)
        with open(path, "wb") as f:
            f.write(data)
        print("wrote %s (%d bytes, %d sectors)" % (path, len(data), len(data) // SECTOR))
    write_expected()
    print("wrote expected outputs under tools/expected/")


if __name__ == "__main__":
    main()
