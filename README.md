# mooniso

纯 MoonBit 实现的 ISO 9660（ECMA-119）光盘映像读写库，零第三方运行依赖。

## 状态

已实现（读取侧）：

- 卷描述符链扫描与主卷描述符（PVD）解析
- 目录记录解析（both-endian 字段校验、时间戳、特殊记录 `.` / `..`）
- 路径解析（大小写不敏感）与目录列举
- 命令行 `info` / `ls`

规划中：

- 文件内容读取（`cat` / 提取）
- Joliet（UCS-2 名称）与 Rock Ridge 扩展
- 映像生成（写入侧）

## 安装

```bash
moon add LL728/mooniso
```

## 命令行

```bash
moon run cmd/main -- info tools/corpus/minimal.iso
moon run cmd/main -- ls   tools/corpus/minimal.iso
moon run cmd/main -- ls   tools/corpus/minimal.iso /SUB
```

输出示例：

```text
volume_id=MOONISO_TEST
block_size=2048
volume_space_size=24
root_extent=20
root_size=2048
```

```text
HELLO.TXT	file	17	2026-01-02T03:04:05
SUB	dir	2048	2026-01-02T03:04:05
```

## 库 API

```moonbit
let image = @mooniso.IsoImage::open(@fs.read_file_to_bytes("image.iso"))
println(image.volume_id())
for entry in image.list_dir("/SUB") {
  println("\{entry.name}\t\{entry.size}")
}
```

## 测试与对拍

```bash
moon test --target wasm-gc          # 单元测试：字节序、目录记录、名称规范化
python tools/gen_fixtures.py        # 生成 tools/corpus/minimal.iso
python tools/check_e2e.py           # 用 CLI 读映像，与期望输出逐行比对
```

测试映像由标准库脚本按 ECMA-119 布局生成，并已用 **Windows CDFS 驱动挂载验证**
（卷标、目录树、嵌套文件内容一致）。CI 在 Linux 上额外用内核 iso9660 驱动挂载同一映像，
把挂载结果与 CLI 输出独立对照。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
