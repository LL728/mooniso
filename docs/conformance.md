# 规范符合性对照

这张表把四件事绑在一起：**规范条款 → 实现位置 → 判别用例 → 独立判据**。
任何一行如果找不到对应代码或对应测试，说明这一行不该出现在 README 的能力列表里。

判据的四种来源互不相同：

| 判据 | 是什么 | 独立于我们的部分 |
|---|---|---|
| pycdlib | 另一份 ISO 实现（Python，LGPL-2.1） | 全部解析逻辑，只在测试期调用 |
| 内核 isofs | Linux 内核的 iso9660 驱动 | 全部解析逻辑，CI 内挂载后比对 |
| Windows CDFS | Windows 自带光盘驱动 | 全部解析逻辑，本地挂载后比对 |
| libarchive | bsdtar 的 ISO 读取路径 | 目录遍历与文件落盘 |

## ECMA-119（ISO 9660）

| 结构 | 条款 | 实现 | 判别用例 | 判据 |
|---|---|---|---|---|
| 卷描述符链（16 号扇区起，类型 1/2/0/255） | 8.1 | `e119_volume.mbt` `scan_volume_descriptors` | `tree_wbtest` walk 用例经由此路径 | pycdlib、内核 |
| 主卷描述符字段（含偏移 7 保留字节） | 8.4 | `e119_volume.mbt` `parse_primary_volume_descriptor` | `write_e119_wbtest` builder 回读 | pycdlib |
| both-endian 数值（小端 + 大端两半必须相等） | 7.3.3 | `e119_byteorder.mbt` `read_u32_both` | `read_u32 both-endian rejects mismatched halves`；`inconsistent both-endian volume size is rejected` | — |
| 目录记录（长度、extent、数据长度、标志、系统用区） | 9.1 | `e119_record.mbt` `parse_directory_record` | `parses a file record`；`too short record is rejected` | pycdlib |
| 记录长度为偶数（奇数名补 1 字节） | 9.1.12 | `write_e119.mbt` `make_dir_record` | `builder produces an image the reader can open` | pycdlib、Windows 挂载 |
| 记录时间戳（17 字节 7 字段） | 9.1.5 | `e119_record.mbt` `RecordDate` | 经 `parses a file record` 断言 | pycdlib |
| 多段文件（标志位 7，按段拼接） | 9.1.6 | `tree.mbt` `read_file` | `list_dir merges multi-extent records`；`read_file concatenates extents in order` | pycdlib（`files.iso` 3 段） |
| 路径表 L / M（写入侧生成，按父目录号与名字排序） | 6.9 | `write_e119.mbt` `path_table_bytes` | `builder produces an image the reader can open` | Windows 挂载（无法进子目录即失败） |
| 目录记录按名字升序存放 | 9.3 | `write_e119.mbt` `build_dir_records` | `directory records are stored in name order` | pycdlib |

路径表只写不读：本库按目录树遍历解析路径，不依赖路径表，因此读取侧没有对应实现。

## Joliet

| 结构 | 条款 | 实现 | 判别用例 | 判据 |
|---|---|---|---|---|
| 补充卷描述符与转义序列 `%/@`、`%/C`、`%/E` | Joliet §3 | `e119_volume.mbt` `find_joliet_descriptor` | 经 `joliet directory record decodes UCS-2 name` 断言 | pycdlib |
| UCS-2BE 名字与代理对 | Joliet §4 | `e119_record.mbt` `decode_ucs2_be` | `decode_ucs2_be joins surrogate pairs`；`decode_ucs2_be stops at NUL` | pycdlib |
| 文件名仍带 `;1` 版本后缀 | Joliet §4 | `e119_record.mbt` `normalize_iso_name` | `normalize strips version and dangling dot` | pycdlib |
| 写入侧 Joliet 目录树与 UCS-2 路径表 | Joliet §4 | `write_e119.mbt` `build`、`path_table_bytes` | `builder keeps long and unicode names through joliet`；`decode ucs2 handles the CJK bytes our writer emits` | Windows 挂载（能列根目录却进不去子目录 = 路径表未用 UCS-2） |

## IEEE P1282（SUSP / Rock Ridge）

| 结构 | 条款 | 实现 | 判别用例 | 判据 |
|---|---|---|---|---|
| SUSP 条目框架 `签名 + 长度 + 版本` | P1282 §4 | `p1282_susp.mbt` `parse_susp` | `RR and SP entries mark presence` | pycdlib |
| `SP` 根目录标记 | §4.1.1 | `write_e119.mbt` `rr_sp_er` | 经 builder 回读用例 | pycdlib（无 SP 则整棵树不按 RR 解析） |
| `ER` 扩展引用（1.09 = `RRIP_1991A`，1.12 = `IEEE_P1282`） | §4.1.2 | `write_e119.mbt` `rr_sp_er` | `rr version 112 emits a 44-byte PX with serial number` | pycdlib 版本判定 |
| `NM` 替换名（UTF-8，可分段） | §4.1.4 | `p1282_susp.mbt`；写入 `write_e119.mbt` `rr_susp` | `NM entry decodes an alternate name` | pycdlib `rr_path` |
| `PX` 权限（1.09 = 36 字节 / 1.12 = 44 字节含序列号） | §4.1.5 | `write_e119.mbt` `rr_susp` | `PX entry carries the POSIX mode`；`rr version 112 emits a 44-byte PX` | pycdlib（PX 长度决定 RR 版本，写错即"版本冲突"） |
| `SL` 符号链接（root 组件 + 各级名字） | §4.1.6 | `p1282_susp.mbt`；写入 `sl_entry` | `SL entry builds an absolute symlink target`；`builder writes rock ridge symlinks` | pycdlib `is_symlink()` |
| `TF` 时间戳 | §4.1.7 | `write_e119.mbt` `rr_susp` | 经 `builder produces an image the reader can open` | pycdlib |
| `CE` 续接区（SUSP 超长时跳到续接块） | §4.1.11 | `p1282_susp.mbt` `parse_susp` | 经 RR 用例路径断言 | pycdlib |

## El Torito

| 结构 | 条款 | 实现 | 判别用例 | 判据 |
|---|---|---|---|---|
| 启动记录卷描述符（类型 0）与启动目录指针（单端小端，偏移 71） | §2.1 | `eltorito.mbt` `find_boot_catalog_lba` | `boot catalog yields platform, media and load address` | pycdlib |
| 校验项（校验和让 16 个 16 位字求和为 0，含 `0x55AA`） | §2.3 | `eltorito.mbt` `boot_catalog_sector` | `boot catalog rejects a broken validation header` | pycdlib（校验和错即拒开） |
| 默认启动项（可启动标志 `0x88`、无仿真、加载扇区数、加载 LBA） | §2.4 | `eltorito.mbt` `parse_boot_catalog` | `builder can produce an El Torito bootable image` | pycdlib `initial_entry` |
| UEFI section header（`0x90` 末段 / `0x91` 后续，平台 `0xEF`） | §2.5 | `eltorito.mbt` `boot_catalog_sector`、`parse_boot_catalog` | `builder can add a UEFI section entry` | pycdlib `catalog.sections`（平台 0xEF、条目数、加载 LBA） |

## ECMA-167（UDF）

| 结构 | 条款 | 实现 | 判别用例 | 判据 |
|---|---|---|---|---|
| 描述符 tag 校验和（除第 4 字节外 16 字节之和） | 3/7.2 | `e167_udf.mbt` `parse_tag` | `tag checksum accepts a well formed descriptor` | pycdlib |
| Anchor Volume Descriptor Pointer（256 号块） | 3/9 | `e167_udf.mbt` `UdfImage::open` | 经 CLI `udf-ls` 端到端 | pycdlib `udf_path` |
| 卷描述符序列（PVD / Partition / LVD / Terminating） | 3/10 | `UdfImage::open` | 同上 | pycdlib |
| File Set Descriptor 与根目录 ICB | 4/14 | `UdfImage::open` | 同上 | pycdlib |
| File Entry 与分配描述符（`short_ad` / `long_ad` / 内嵌数据） | 4/14.9 | `read_entry`、`node_data` | 经 `udf-ls`、`udf-cat` | pycdlib |
| File Identifier Descriptor 与压缩标识（8 = Latin-1，16 = UTF-16BE） | 4/14.4 | `parse_fids`、`decode_dstring` | `dstring decodes latin-1 and utf-16` | pycdlib（中文名 `说明.txt`） |

## 写入侧布局（跨规范）

| 结构 | 依据 | 实现 | 判别用例 | 判据 |
|---|---|---|---|---|
| 描述符顺序：16 = PVD，17 = 启动记录（El Torito 要求紧跟 PVD），其后 SVD，最后结束符 | ECMA-119 8.1 + El Torito 2.1 | `write_e119.mbt` `build` | `builder can produce an El Torito bootable image` | pycdlib（错位即报 "Boot Record must be at extent 17"） |
| 块分配顺序：描述符 → 路径表 → ISO 目录 → Joliet 目录 → 文件 → 启动目录 | — | `build` | `builder produces an image the reader can open` | pycdlib、内核挂载 |
| 名字级别 1（8.3 + `;1`）/ 2（≤31）/ 3（≤207），同目录去重 | ECMA-119 7.5 | `iso_name` | `name level 2 keeps names up to 31 chars in the iso tree` | pycdlib |

## 边界：每条都对应规范原文或明确的职责边界

| 不做的事 | 依据 |
|---|---|
| UDF 写入 | 职责边界：本库写入侧产出 ISO 9660 + Joliet + Rock Ridge，UDF 侧只提供读取 |
| UDF 的 VAT（虚拟分配表）、元数据分区 | ECMA-167 4/15、4/10：多区段与元数据分区的写入语义，读侧未覆盖，写入侧不在范围 |
| 单个文件 > 4 GiB 的 UDF 读取 | ECMA-167 4/14.9 的 64 位信息长度：本实现按 32 位长度处理，超出时报错而不是截断 |
| 多段文件写入 | ECMA-119 9.1.6：读侧已合并多段，写侧不拆分 |
| CL / PL 深层目录重定位（写入） | IEEE P1282 §4.1.8 / §4.1.9：写侧不搬移目录，>8 层路径由 Joliet / Rock Ridge 名字承载 |
| zisofs 压缩文件、HFS / HFS+ 混合 | 不在 ISO 9660 本体与本项目声明的范围 |
