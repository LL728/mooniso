#!/usr/bin/env python3
"""UDF 版本边界：不支持的布局必须显式拒绝，不能静默误读。

    python tools/oracle/udf_bounds.py

构造只含"某个分区映射 + 空描述符序列"的最小映像，断言 CLI 的报错与退出码：
    - 元数据分区（UDF 2.50+ 的必需寻址层）→ [UDF-LAYOUT]
    - 虚拟分区（VAS/VAT，多区段写入）      → [UDF-LAYOUT]
    - 普通 Type 1 分区                      → 不在本脚本断言（需要完整映像，另有单测覆盖）
"""

import os
import struct
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SECTOR = 2048
BLOCKS = 400


def build(path, map_kind):
    buf = bytearray(SECTOR * BLOCKS)

    def tag(off, desc_id):
        buf[off:off + 16] = b"\x00" * 16
        buf[off] = desc_id
        buf[off + 2] = 1
        buf[off + 4] = sum(buf[off + i] for i in range(16) if i != 4) % 256

    def le32(off, value):
        buf[off:off + 4] = struct.pack("<I", value)

    # Anchor（第 256 块）→ 描述符序列从第 300 块起
    tag(256 * SECTOR, 2)
    le32(256 * SECTOR + 16, SECTOR * 3)
    le32(256 * SECTOR + 20, 300)
    tag(300 * SECTOR, 1)                     # 主卷描述符
    tag(301 * SECTOR, 5)                     # 分区描述符：分区起点 400
    le32(301 * SECTOR + 188, 400)
    tag(302 * SECTOR, 6)                     # 逻辑卷描述符
    le32(302 * SECTOR + 212, 2048)           # 逻辑块大小
    le32(302 * SECTOR + 248, 10)             # File Set 位置
    le32(302 * SECTOR + 250, 401)
    le32(302 * SECTOR + 264, 64)             # 映射表长度
    le32(302 * SECTOR + 268, 1)              # 映射个数
    base = 302 * SECTOR
    buf[base + 440] = 2                      # Type 2 映射
    buf[base + 441] = 64
    name = map_kind.encode("ascii")
    buf[base + 443:base + 443 + len(name)] = name
    with open(path, "wb") as f:
        f.write(buf)


def run_cli(args):
    cmd = ["moon", "run", "--target", "js", "cmd/main", "--"] + args
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    return proc.returncode, proc.stdout.strip()


def main():
    failures = []
    cases = [
        ("*UDF Metadata Partition", "udf-metadata-partition"),
        ("*UDF Virtual Partition", "udf-virtual-partition"),
        ("*UDF Sparable Partition", "udf-sparable-partition"),
    ]
    with tempfile.TemporaryDirectory(prefix="mooniso-udf-bounds-") as tmp:
        for name, layout in cases:
            path = os.path.join(tmp, layout + ".iso")
            build(path, name)
            code, out = run_cli(["udf-ls", path])
            if code != 1:
                failures.append("%s：退出码应为 1，实际 %d（输出 %r）" % (layout, code, out))
            elif "[UDF-LAYOUT]" not in out or layout not in out:
                failures.append("%s：诊断不符，实际 %r" % (layout, out))
            else:
                print("ok   %s 被显式拒绝（退出码 1）" % layout)

            code, out = run_cli(["udf-cat", path, "/x"])
            if code != 1:
                failures.append("%s udf-cat：退出码应为 1，实际 %d" % (layout, code))
    if failures:
        print("\n".join(failures))
        print("FAILED")
        sys.exit(1)
    print("ALL PASS")


if __name__ == "__main__":
    main()
