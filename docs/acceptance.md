# 验收断言台账

每条断言对应申报书或 README 的一句声明，附可复现证据。
新增能力时追加一行；验收时直接引用本表，不再临时翻代码。

| 编号 | 断言 | 证据（测试名 / 命令 / 文件） | 日期 | 提交 |
|---|---|---|---|---|
| A01 | 卷描述符链解析（ECMA-119 8.1） | `impl/e119_volume.mbt` `scan_volume_descriptors`；`tests: walk lists the whole tree depth first` | 2026-11-23 | d39cedf |
| A02 | 目录记录解析（9.1） | `impl/e119_record.mbt` `parse_directory_record`；`tests: parses a file record / too short record is rejected` | 2026-11-23 | d39cedf |
| A03 | both-endian 字段一致性 | `impl/e119_byteorder.mbt`；`tests: read_u32 both-endian rejects mismatched halves / inconsistent both-endian volume size is rejected` | 2026-11-23 | d39cedf |
| A04 | 多段文件合并读取 | `impl/tree.mbt`；`tests: read_file concatenates extents in order / list_dir merges multi-extent records into one entry` | 2026-11-23 | d39cedf |
| A05 | Joliet UCS-2 名字（含代理对） | `impl/joliet.mbt`；`tests: decode_ucs2_be joins surrogate pairs / joliet directory record decodes UCS-2 name` | 2026-11-23 | d39cedf |
| A06 | Rock Ridge SUSP（NM/PX/SL/TF，1.09 与 1.12） | `impl/p1282_susp.mbt`；`tests: SL entry builds an absolute symlink target / rr version 112 emits a 44-byte PX with serial number` | 2026-11-23 | d39cedf |
| A07 | El Torito 启动目录与 UEFI section | `impl/eltorito.mbt`；`tests: boot catalog yields platform, media and load address / builder can add a UEFI section entry` | 2026-11-23 | d39cedf |
| A08 | boot info table 覆盖整幅映像 | `tests: boot info table uses the real boot image length and covers the whole image` | 2026-11-23 | d39cedf |
| A09 | UDF 1.02 完整读取（261/259/260/258/257/AD） | `impl/e167_udf.mbt`；`tests: udf follows an indirect entry / udf follows an allocation extent continuation / udf treats a terminal entry as an empty file` | 2026-11-23 | d39cedf |
| A10 | 64 位信息长度（文件 > 4 GiB） | `read_length64 -> Int64`；`tests: udf reports a file over 4 GiB with full 64 bit length` | 2026-11-23 | d39cedf |
| A11 | 大映像数据源（映像本身 > 2 GiB） | `impl/source.mbt` `ImageSource`；`tests: udf reads a 6 GiB file inside a 16 GiB image without loading the image`（`host_bytes=41046`） | 2026-11-23 | d39cedf |
| A12 | 2.50+ 结构显式拒绝 | `tests: image that declares a metadata partition is rejected explicitly`；`python tools/oracle/udf_bounds.py` ALL PASS | 2026-11-23 | d39cedf |
| A13 | 目录环不会无限递归 | `tests: directory that points back at its ancestor is stopped, not recursed forever` | 2026-11-23 | d39cedf |
| A14 | 32 位溢出拒绝而非回绕 | `tests: block number that would overflow 32 bit is rejected, not wrapped / read_range rejects a length that would overflow 32 bit` | 2026-11-23 | d39cedf |
| A15 | CLI 十子命令与退出码 0/1/2 | `cmd/main/main.mbt`；`python tools/oracle/cli_expectations.py` ALL PASS | 2026-11-23 | d39cedf |
| A16 | 与 pycdlib 读取侧对拍 6 目录 | `python tools/oracle/pycdlib_read.py` → `ALL PASS (6 directories)` | 2026-11-23 | d39cedf |
| A17 | 与 pycdlib 写入侧对拍 | `python tools/oracle/pycdlib_write.py` → `ALL PASS` | 2026-11-23 | d39cedf |
| A18 | 内核挂载比对（CI） | `.github/workflows/ci.yml:119-133`；本机无 WSL/Docker，未本地复现 | 2026-11-23 | d39cedf |
| A19 | 双后端测试 | `moon test --target wasm-gc` 88/88；`--target js` 88/88（CI run 46028391954 同结果） | 2026-11-27 | be3c73c |
| A20 | 已发布 mooncakes 0.7.1 | `~/.moon/registry/index/user/LL728/mooniso.index` → `"version":"0.7.1"`；全新工程 `moon add` → `@0.7.1`；`moon view` → `Latest: 0.7.1 / Versions: 13` | 2026-11-27 | be3c73c |

| A21 | 工具链下限 `moonc >= 1.0.0-rc1`（验收第 1 条） | CI 四个作业均打印 `moonc v1.0.0-rc1+3c0520448 (2026-11-26)`；run [46028391954](https://github.com/LL728/mooniso/actions/runs/46028391954) 的 `工具链版本` 步骤，`be3c73c` 起 3 个作业各一行 | 2026-11-27 | be3c73c |
| A22 | README 示例在全新工程可逐字复现 | 临时工程 `moon add LL728/mooniso` → `@0.7.1`；`moon check` exit 0；运行输出 `volume=MOONISO_TEST / len=18 / built=53248` | 2026-11-27 | be3c73c |
| A23 | 大映像输入上限已突破（`Bytes` 32 位限制） | 全新工程用 `ImageSource::new(6442450944L, ...)` + `open_with_source` 打开空源 → 正确抛 `Truncated`；真实语料 → `block=2048 / size=10 / head=3` | 2026-11-27 | be3c73c |

## 本机工具链说明（验收第 1 条）

本机为 Windows，`moonc` 停在 `v0.10.20+65efd5b93`，无法本地点定安装 1.0.0-rc1，原因均已实测：

- `cli.moonbitlang.com` 只发布 `latest`（`binaries/1.0.0-rc1/...`、`1.0.0-rc.1`、`v1.0.0-rc1` 全部 403）；
- `latest` 的 Windows 包同样 403（该分发只打包 Linux / macOS）；
- `install.sh` 的 `uname -ms` 分支只有 `Darwin` 与 `Linux`，无 Windows；
- `moon upgrade` 需要交互终端（`Error: IO error: not a terminal`）；
- WSL 未安装发行版（`wsl.exe -e echo hello` → exit 1，提示 `wsl --install`）。

因此 rc1 证据以 CI（Ubuntu）为准：`.github/workflows/ci.yml` 三个作业在安装后各跑一次
`moon version --all`（`be3c73c` 加入），日志可独立核对。本机仍可完成 `moon fmt --check`、
`moon check --deny-warn`、`moon test`（88/88 双后端）与四个对拍脚本，全部通过。
