# 测试映像

六张映像，两种来源。**自建的逐字节可复现**，CI 每次重建并比对；**pycdlib 侧的不含时间戳控制，每次生成都会变**，只作对拍输入。

| 映像 | 内容 | 生成 | 可复现 | 被谁使用 |
|---|---|---|---|---|
| `minimal.iso` | 24 块：`HELLO.TXT`(17B)、`SUB/INNER.TXT`(11B) | `tools/fixtures/build_corpus.py` | 是 | `oracle/cli_expectations.py`、内核挂载 |
| `files.iso` | 26 块：`BIG.BIN` 5000B 拆 3 段（2048+2048+904）、`TEXT.TXT`、`EMPTY.TXT` | 同上 | 是 | 多段合并与 0 字节文件的端到端 |
| `joliet.iso` | Joliet 名字：`Hello.txt`、`资料/说明.txt`、64 字符长名 | `tools/fixtures/pycdlib_corpus.py` | 否（含生成时间戳） | `oracle/pycdlib_read.py` |
| `rockridge.iso` | Rock Ridge：`Hello.txt`、`Docs/Note.txt`、`Docs/link` 符号链接 | 同上 | 否 | 同上 |
| `boot.iso` | El Torito：`/BOOT.BIN` 启动项（4 扇区无仿真） | 同上 | 否 | 同上 |
| `udf.iso` | ISO 9660 + UDF 2.60 双格式：`hello.txt`、`Docs/note.md`、`Docs/说明.txt` | `tools/fixtures/udf_corpus.py` | 否 | `udf-ls` / `udf-cat` 对拍 |

`tools/expected/` 是与这些映像配套的期望输出：自建映像的文本输出由 `build_corpus.py` 一并写出（改行为就会 diff），
pycdlib 侧的清单由 pycdlib 自己列出，作为**独立实现**的基准。
