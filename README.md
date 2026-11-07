# mooniso

纯 MoonBit 实现的 ISO 9660（ECMA-119）光盘映像读写库，零第三方运行依赖。

## 能力

读取：

- 卷描述符链扫描、主卷描述符（PVD）与补充卷描述符（Joliet SVD）解析
- 目录记录解析（both-endian 校验、时间戳、`.` / `..`、多段文件合并）
- 路径解析（大小写不敏感）与目录列举
- 文件内容读取（跨扇区、多段文件、0 字节文件、越界拒绝）
- Joliet（UCS-2，含代理对）与 Rock Ridge（NM / PX / SL / CE 续接区）
- El Torito 启动目录（启动标志、平台、媒体类型、加载地址、UEFI section header）
- **UDF（ECMA-167）读取**：Anchor、描述符序列、File Set、File Entry、FID（含 UTF-16 名字）

写入：

- 从目录树生成映像：ISO 9660 level 1 名字（自动 8.3 化与去重）+ Joliet + Rock Ridge
- 可生成 **El Torito 可启动映像**：BIOS 启动项 + UEFI section header（双启动），含校验和
- 可分别关闭 Joliet / Rock Ridge；L、M 路径表按规范生成

## 演示

![demo](docs/demo/poster.png)

终端动画演示（真实命令、真实输出）：[docs/demo/mooniso-demo.mp4](docs/demo/mooniso-demo.mp4)，
可用 `python tools/make_demo_video.py` 重新生成。

## 安装

```bash
moon add LL728/mooniso
```

## 命令行

```bash
moon run cmd/main -- info    image.iso               # 卷信息 + 启动信息
moon run cmd/main -- ls      image.iso /SUB          # 列目录
moon run cmd/main -- cat     image.iso /HELLO.TXT    # 打印文本
moon run cmd/main -- extract image.iso /BIG.BIN out  # 落盘（二进制安全）
moon run cmd/main -- tree    image.iso               # 递归列出整棵树
moon run cmd/main -- extract-all image.iso ./out     # 整树导出（跳过符号链接）
moon run cmd/main -- verify  image.iso               # 结构体检
moon run cmd/main -- udf-ls  image.iso /Docs         # 走 UDF 视角列目录
moon run cmd/main -- udf-cat image.iso /hello.txt    # 走 UDF 视角读文件
moon run cmd/main -- create  out.iso ./some-dir      # 从目录生成映像
moon run cmd/main -- create  out.iso ./some-dir --boot /boot.bin --efi /efi.img   # BIOS+UEFI 双启动
```

最小可运行示例：

```bash
moon run examples/basic     # 内存里造映像 -> 读回 -> 列出 -> 校验
```

## 库 API

```moonbit
// 读
let image = @mooniso.IsoImage::open(@fs.read_file_to_bytes("image.iso"))
println(image.volume_id())
for entry in image.list_dir("/SUB") {
  println("\{entry.name}\t\{entry.size}")
}
let bytes = image.read_file("/HELLO.TXT")

// 写
let builder = @mooniso.IsoBuilder::new()
builder.volume_id("MY_VOLUME")
builder.add_directory("/Docs")
builder.add_file("/Hello.txt", b"hi")
let image_bytes = builder.build()
```

## 测试与对拍

```bash
moon test --target wasm-gc              # 单元测试：字节序、目录记录、Joliet、SUSP、El Torito、生成器回读
python tools/gen_fixtures.py            # 生成 tools/corpus/*.iso（自身格式，可复现）
python tools/check_e2e.py               # CLI 输出与期望逐行比对

python tools/gen_fixtures_pycdlib.py    # 用 pycdlib 生成 Joliet/Rock Ridge/El Torito 映像与基准清单
python tools/gen_fixtures_udf.py        # 用 pycdlib 生成 UDF 2.60 映像与基准清单
python tools/check_compat.py            # 读取侧与 pycdlib 对拍
python tools/check_roundtrip.py         # 写入侧：生成的映像由 pycdlib 读回比对（含可启动映像）
```

对拍基线来自独立实现：**pycdlib**（Python）、**libarchive**、**Windows CDFS 驱动**、
**Linux 内核 iso9660 驱动**（CI 中挂载后逐字节比对）。

## 已知边界

- 只支持 ISO 9660 level 1 名字映射（写入侧）；Rock Ridge 版本为 1.09
- UDF 只读：不支持 VAT（多区段写入）、元数据分区与 >4 GiB 的单个文件
- 写入侧不生成 UDF；El Torito 只写单个 UEFI section（多 section / 启动信息表未写）

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
