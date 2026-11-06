// mooniso 命令行：info（卷信息）与 ls（列目录）。
//
// 输出是稳定的纯文本，便于与系统挂载结果做逐行对拍。

///|
fn usage() -> Unit {
  println("usage:")
  println(
    "  mooniso info    <image.iso>                print volume information",
  )
  println(
    "  mooniso ls      <image.iso> [path]         list a directory (default /)",
  )
  println(
    "  mooniso cat     <image.iso> <path>         print a text file to stdout",
  )
  println(
    "  mooniso extract <image.iso> <path> <out>   write a file to disk (binary safe)",
  )
}

///|
fn print_info(image : @mooniso.IsoImage) -> Unit raise @mooniso.IsoError {
  let root = image.root()
  println("volume_id=\{image.volume_id()}")
  println("block_size=\{image.block_size()}")
  println("volume_space_size=\{image.volume_space_size()}")
  println("root_extent=\{root.extent}")
  println("root_size=\{root.size}")
  print_boot(image)
}

///|
/// 打印 El Torito 启动信息（不可启动的映像什么都不打印）。
fn print_boot(image : @mooniso.IsoImage) -> Unit raise @mooniso.IsoError {
  match image.boot_info() {
    Some(info) => {
      println("bootable=\{info.bootable}")
      println("boot_platform=\{info.platform_id}")
      println("boot_media=\{info.media_type}")
      println("boot_sectors=\{info.sector_count}")
      println("boot_load_lba=\{info.load_lba}")
    }
    None => ()
  }
}

///|
fn print_listing(
  image : @mooniso.IsoImage,
  path : String,
) -> Unit raise @mooniso.IsoError {
  for entry in image.list_dir(path) {
    let kind = if entry.is_dir() {
      "dir"
    } else if entry.is_symlink() {
      "link"
    } else {
      "file"
    }
    let suffix = match entry.symlink_target {
      Some(target) => "\t-> \{target}"
      None => ""
    }
    println(
      "\{entry.name}\t\{kind}\t\{entry.size}\t\{entry.date.to_iso_string()}" +
      suffix,
    )
  }
}

///|
/// 把宿主 I/O 错误转换成库的错误类型，避免调用方同时处理两套错误。
fn fs_read_dir(path : String) -> ArrayView[String] raise @mooniso.IsoError {
  @fs.read_dir(path) catch {
    @fs.IOError::IOError(msg) => raise @mooniso.IsoError::HostIoError(msg)
  }
}

///|
fn fs_is_dir(path : String) -> Bool raise @mooniso.IsoError {
  @fs.is_dir(path) catch {
    @fs.IOError::IOError(msg) => raise @mooniso.IsoError::HostIoError(msg)
  }
}

///|
fn fs_read_bytes(path : String) -> Bytes raise @mooniso.IsoError {
  @fs.read_file_to_bytes(path) catch {
    @fs.IOError::IOError(msg) => raise @mooniso.IsoError::HostIoError(msg)
  }
}

///|
fn fs_write_bytes(path : String, data : Bytes) -> Unit raise @mooniso.IsoError {
  @fs.write_bytes_to_file(path, data) catch {
    @fs.IOError::IOError(msg) => raise @mooniso.IsoError::HostIoError(msg)
  }
}

///|
/// 取路径最后一段（同时兼容 / 与 \\ 分隔符）。
fn base_name(path : String) -> String {
  let chars = path.to_array()
  let mut last = -1
  for i = 0; i < chars.length(); i = i + 1 {
    let code = chars[i].to_int()
    if code == 47 || code == 92 {
      last = i
    }
  }
  path[last + 1:].to_owned()
}

///|
/// 递归把本地目录加进映像。
fn pack_dir(
  builder : @mooniso.IsoBuilder,
  fs_dir : String,
  iso_dir : String,
) -> Unit raise @mooniso.IsoError {
  for entry in fs_read_dir(fs_dir) {
    // read_dir 只给出条目名，需要自己拼回完整路径
    let name = base_name(entry)
    let child_fs = if fs_dir.has_suffix("/") {
      fs_dir + name
    } else {
      fs_dir + "/" + name
    }
    let iso_path = if iso_dir == "/" {
      "/" + name
    } else {
      iso_dir + "/" + name
    }
    if fs_is_dir(child_fs) {
      builder.add_directory(iso_path)
      pack_dir(builder, child_fs, iso_path)
    } else {
      builder.add_file(iso_path, fs_read_bytes(child_fs))
    }
  }
}

///|
fn create_image(
  out_path : String,
  src_dir : String,
) -> Unit raise @mooniso.IsoError {
  let builder = @mooniso.IsoBuilder::new()
  builder.volume_id("MOONISO")
  pack_dir(builder, src_dir, "/")
  fs_write_bytes(out_path, builder.build())
  println("created \{out_path} from \{src_dir}")
}

///|
fn main {
  let args = @env.args()
  // 各后端 argv 形状不同：wasm-gc/native 是 [程序, ...]，js 是 [node, 脚本.js, ...]
  let mut base = 1
  if base < args.length() && args[base].has_suffix(".js") {
    base += 1
  }
  if base + 1 >= args.length() {
    usage()
    return
  }
  let command = args[base]
  try {
    if command == "create" {
      if base + 2 >= args.length() {
        usage()
        return
      }
      create_image(args[base + 1], args[base + 2])
      return
    }
    if command != "info" &&
      command != "ls" &&
      command != "cat" &&
      command != "extract" {
      usage()
      return
    }
    let path = if base + 2 < args.length() { args[base + 2] } else { "/" }
    let image = @mooniso.IsoImage::open(@fs.read_file_to_bytes(args[base + 1]))
    if command == "info" {
      print_info(image)
    } else if command == "ls" {
      print_listing(image, path)
    } else if command == "cat" {
      println(@utf8.decode_lossy(image.read_file(path)))
    } else {
      // extract 需要第三个参数：输出路径
      if base + 3 >= args.length() {
        usage()
        return
      }
      @fs.write_bytes_to_file(args[base + 3], image.read_file(path))
      println(
        "extracted \{path} -> \{args[base + 3]} (\{image.file_size(path)} bytes)",
      )
    }
  } catch {
    @mooniso.IsoError::Truncated => println("ERROR\ttruncated image")
    @mooniso.IsoError::BadBothEndian =>
      println("ERROR\tboth-endian fields disagree")
    @mooniso.IsoError::BadSignature =>
      println("ERROR\tnot an ISO 9660 image (missing CD001)")
    @mooniso.IsoError::BadDescriptor(code) =>
      println("ERROR\tbad volume descriptor (\{code})")
    @mooniso.IsoError::NotFound(p) => println("ERROR\tno such path: \{p}")
    @mooniso.IsoError::NotDirectory(p) =>
      println("ERROR\tnot a directory: \{p}")
    @mooniso.IsoError::IsDirectory(p) => println("ERROR\tis a directory: \{p}")
    @mooniso.IsoError::IsSymlink(p) => println("ERROR\tis a symlink: \{p}")
    @mooniso.IsoError::HostIoError(msg) => println("ERROR\tI/O: \{msg}")
    @mooniso.IsoError::BadDirectoryRecord(len) =>
      println("ERROR\tbad directory record (\{len} bytes)")
    @fs.IOError::IOError(msg) => println("ERROR\tI/O: \{msg}")
    _ => println("ERROR\tunexpected failure")
  }
}
