// 最小使用样例：在内存里生成一个映像，再把它读回来。
//
//     moon run examples/basic

///|
fn main {
  try {
    // 1) 生成映像
    let builder = @mooniso.IsoBuilder::new()
    builder.volume_id("MOONISO_DEMO")
    builder.add_file("/hello.txt", @utf8.encode("hello from mooniso\n"))
    builder.add_directory("/Docs")
    builder.add_file("/Docs/说明.txt", @utf8.encode("中文内容\n"))
    let image_bytes = builder.build()
    println("built image: \{image_bytes.length()} bytes")

    // 2) 读回来
    let image = @mooniso.IsoImage::open(image_bytes)
    println("volume_id=\{image.volume_id()}")
    println(
      "joliet=\{image.uses_joliet()}  rock_ridge=\{image.has_rock_ridge()}",
    )
    for entry in image.walk("/") {
      let kind = if entry.is_dir {
        "dir"
      } else if entry.is_symlink {
        "link"
      } else {
        "file"
      }
      println("\{entry.path}\t\{kind}\t\{entry.size}")
    }
    println("content=\{@utf8.decode_lossy(image.read_file("/hello.txt"))}")
    let report = image.validate()
    println(
      "validate: directories=\{report.directories} files=\{report.files} problems=\{report.problems.length()}",
    )
  } catch {
    @mooniso.IsoError::Truncated => println("ERROR truncated")
    @mooniso.IsoError::BadSignature => println("ERROR not an ISO image")
    @mooniso.IsoError::BadDescriptor(code) =>
      println("ERROR bad descriptor \{code}")
    @mooniso.IsoError::NotFound(path) => println("ERROR not found \{path}")
    _ => println("ERROR unexpected failure")
  }
}
