# 字段级坑位记录

这里记的是"按规范读完仍然会写错"的地方——不是概念解释，是**具体字节、具体偏移、具体后果**。
每条都附本仓库的判别方式：改回去，哪条测试或哪个对拍会变红。

| # | 现象 | 根因（字节级） | 出处 | 改回去会怎样 |
|---|---|---|---|---|
| 1 | 一张正常光盘被报 `BadBothEndian`，而且后续字段全部错位 | 主卷描述符第 7 字节是**保留字节**，字段从偏移 8 才开始；忘了跳过会把 32 字节系统标识错读成 31 字节 | ECMA-119 8.4 | `write_e119_wbtest` 的 builder 回读首条失败 |
| 2 | 启动目录指针读成天文数字，El Torito 整段不可用 | 启动记录卷描述符里的启动目录位置在**偏移 71**，且是**单端小端**（其余字段多为 both-endian，这里不是） | El Torito 2.1 | `boot catalog yields platform, media and load address` 失败 |
| 3 | 校验项读出来总差 2 字节 | 校验项格式是 `0x01 + 平台 + 2 字节保留 + 24 字节标识 + 校验和 + 0x55AA`，那 2 字节保留容易被漏 | El Torito 2.3 | `boot catalog rejects a broken validation header` 不触发 |
| 4 | 校验和算出来总是不对，独立实现拒绝打开 | 校验和要让校验项 16 个小端 16 位字之和为 0，**必须把固定的 `0x55AA` 也计入**；先算后写就会漏掉它们 | El Torito 2.3 | pycdlib 报 "Validation entry checksum not correct" |
| 5 | 一张明明写对的映像，pycdlib 报"启动记录必须在 17 号块" | 描述符顺序是 PVD(16) → 启动记录(**17**) → 补充卷 → 结束符；启动记录放到 SVD 之后即不合约定 | El Torito 2.1 + 实现约定 | `pycdlib_write.py` 的启动项比对失败 |
| 6 | Rock Ridge 明明只用了 1.09，独立实现却报"版本冲突（1.09 vs 1.12）" | `PX` 条目长度决定版本推断：36 字节 = 1.09（4 个 both-endian 字段），44 字节 = 1.12（多 8 字节序列号）。两者混在一张盘上即冲突 | IEEE P1282 4.1.5 | `rr version 112 emits a 44-byte PX with serial number` 失败 |
| 7 | 独立实现不认这张盘是 Rock Ridge | `ER` 条目体是 `LEN_ID / LEN_DES / LEN_SRC / EXT_VER` 四个字节，然后依次跟标识、描述、来源；顺序写错就解析不出来 | IEEE P1282 4.1.2 | pycdlib 的 `rr_path` 退化成 ISO 名字 |
| 8 | 中文文件名变成一串问号或乱码 | `NM` 的名字按 UTF-8 存；按 ASCII 逐字节截断会把多字节字符切断 | IEEE P1282 4.1.4 | `builder keeps long and unicode names through joliet` 失败 |
| 9 | Windows 能列出根目录，但点不进任何子目录 | Joliet 的**路径表**名字也必须是 UCS-2；只把目录记录写成 UCS-2 不够 | Joliet 4 | Windows 挂载后子目录访问失败 |
| 10 | 目录记录长度算出来是奇数，解析器读越界 | 文件标识符后面要补 1 字节空字节把记录长度凑成偶数，且记录长度字段本身要最后回填 | ECMA-119 9.1.12 | `parses a file record` 失败 |
| 11 | UDF 描述符几乎全部被判无效 | tag 的校验和是"除第 4 字节外 16 字节之和 mod 256"，第 4 字节本身是校验和字段 | ECMA-167 3/7.2 | `tag checksum accepts a well formed descriptor` 失败 |
| 12 | UDF 大文件读到中途长度对不上 | 信息长度在 File Entry **偏移 56**、是 64 位；按 32 位读会截断 | ECMA-167 4/14.9 | 本实现对 >4 GiB 报错而非截断 |
| 13 | 大文件只读出第一段 | 目录记录标志位 **7**（0x80）表示多段，同名的后续记录要继续拼接 | ECMA-119 9.1.6 | `list_dir merges multi-extent records into one entry` 失败 |

写新代码时的自检顺序：先确认字段偏移与字节序（1、2、11），再确认长度与对齐（3、10），
最后确认版本与编码（6、8、9）。这三类错误的表现几乎一样——"独立实现不认"，但改的地方完全不同。
