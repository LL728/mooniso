// 与 README「安装与最小示例」逐字对应：造一张映像，再读回来、列树、区间读取、体检。
//
//     moon run examples/readme_demo

///|
fn main {
  try {
    // 造一张映像
    let builder = @mooniso.IsoBuilder::new()
    builder.volume_id("MOONISO_DEMO")
    builder.add_directory("/Docs")
    builder.add_file("/Docs/note.md", @utf8.encode("# note\n"))
    builder.add_symlink("/link.txt", "/Docs/note.md")
    let image_bytes = builder.build() // -> Bytes
    println("built=\{image_bytes.length()} bytes")

    // 读一张映像
    let image = @mooniso.IsoImage::open(image_bytes)
    println(image.volume_id()) // 卷标
    for entry in image.walk("/") { // 递归列树
      println("\{entry.path}\t\{entry.size}")
    }
    let data = image.read_file("/Docs/note.md") // 取内容（多段、跨扇区、越界拒绝）
    println("read_file=\{data.length()} bytes")

    // 区间读取：只取大文件的一段，避免整块拷贝
    let head = image.read_range("/Docs/note.md", 0, 4)
    println("read_range=\{head.length()} bytes")

    let report = image.validate()
    println("validate: problems=\{report.problems.length()}")
  } catch {
    _ => println("ERROR")
  }
}
