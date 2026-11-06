# mooniso

纯 MoonBit 实现的 ISO 9660（ECMA-119）光盘映像读写库，零第三方运行依赖。

## 能力

读取：

- 卷描述符链扫描、主卷描述符（PVD）与补充卷描述符（Joliet SVD）解析
- 目录记录解析（both-endian 校验、时间戳、`.` / `..`、多段文件合并）
- 路径解析（大小写不敏感）与目录列举
- 文件内容读取（跨扇区、多段文件、0 字节文件、越界拒绝）
- Joliet（UCS-2，含代理对）与 Rock Ridge（NM / PX / SL / CE 续接区）
- El Torito 启动目录（启动标志、平台、媒体类型、加载地址）

写入：

- 从目录树生成映像：ISO 9660 level 1 名字（自动 8.3 化与去重）+ Joliet + Rock Ridge
- 可分别关闭 Joliet / Rock Ridge；L、M 路径表按规范生成

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
moon run cmd/main -- create  out.iso ./some-dir      # 从目录生成映像
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
python tools/check_compat.py            # 读取侧与 pycdlib 对拍
python tools/check_roundtrip.py         # 写入侧：生成的映像由 pycdlib 读回比对
```

对拍基线来自独立实现：**pycdlib**（Python）、**libarchive**、**Windows CDFS 驱动**、
**Linux 内核 iso9660 驱动**（CI 中挂载后逐字节比对）。

## 已知边界

- 只支持 ISO 9660 level 1 名字映射（写入侧）；Rock Ridge 版本为 1.09
- 不写 UDF、不写 El Torito 启动项（读取支持）
- 目录数据超过 4 GiB、且无 Joliet/Rock Ridge 的极端映像未做专门优化

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
