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
      for i = 1; i < info.entries.length(); i = i + 1 {
        let entry = info.entries[i]
        println(
          "boot_entry_\{i}=platform=\{entry.platform_id},sectors=\{entry.sector_count},load_lba=\{entry.load_lba}",
        )
      }
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
fn fs_create_dir(path : String) -> Unit raise @mooniso.IsoError {
  if @fs.path_exists(path) {
    return
  }
  @fs.create_dir(path) catch {
    @fs.IOError::IOError(msg) => raise @mooniso.IsoError::HostIoError(msg)
  }
}

///|

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
fn print_udf_listing(
  image : @mooniso.UdfImage,
  path : String,
) -> Unit raise @mooniso.IsoError {
  for entry in image.list_dir(path) {
    let kind = if entry.is_dir { "dir" } else { "file" }
    println("\{entry.name}\t\{kind}\t\{entry.size}")
  }
}

///|
fn print_tree(
  image : @mooniso.IsoImage,
  path : String,
) -> Unit raise @mooniso.IsoError {
  for entry in image.walk(path) {
    let kind = if entry.is_dir { "dir" } else { "file" }
    println("\{entry.path}\t\{kind}\t\{entry.size}")
  }
}

///|
fn extract_all(
  image : @mooniso.IsoImage,
  path : String,
  out_dir : String,
) -> Unit raise @mooniso.IsoError {
  fs_create_dir(out_dir)
  let mut count = 0
  let mut skipped = 0
  for entry in image.walk(path) {
    let target = out_dir + entry.path
    if entry.is_dir {
      fs_create_dir(target)
    } else if entry.is_symlink {
      // 符号链接不落地（目标可能指向映像外），只统计
      skipped = skipped + 1
    } else {
      fs_write_bytes(target, image.read_file(entry.path))
      count = count + 1
    }
  }
  println(
    "extracted \{count} files to \{out_dir} (skipped \{skipped} symlinks)",
  )
}

///|
fn verify_image(image : @mooniso.IsoImage) -> Unit {
  let report = image.validate()
  println("directories=\{report.directories}")
  println("files=\{report.files}")
  println("symlinks=\{report.symlinks}")
  println("bytes=\{report.total_bytes}")
  println("joliet=\{image.uses_joliet()}")
  println("rock_ridge=\{image.has_rock_ridge()}")
  if report.problems.length() == 0 {
    println("OK")
  } else {
    for problem in report.problems {
      println("PROBLEM\t\{problem}")
    }
    println("FAILED (\{report.problems.length()} problems)")
  }
}

///|
fn create_image(
  out_path : String,
  src_dir : String,
  boot_path : String?,
  efi_path : String?,
  links : Array[String],
  name_level : Int32,
  rr_version : Int32,
) -> Unit raise @mooniso.IsoError {
  let builder = @mooniso.IsoBuilder::new()
  builder.volume_id("MOONISO")
  builder.name_level(name_level)
  builder.rr_version(rr_version)
  pack_dir(builder, src_dir, "/")
  match boot_path {
    Some(path) => {
      builder.boot_image(path, 4, 0)
      println("boot image: \{path}")
    }
    None => ()
  }
  match efi_path {
    Some(path) => {
      builder.boot_image_efi(path, 4)
      println("efi image: \{path}")
    }
    None => ()
  }
  for link in links {
    // 形式：/path=target
    let mut at = -1
    let chars = link.to_array()
    for i = 0; i < chars.length(); i = i + 1 {
      if chars[i].to_int() == 61 {
        at = i
        break
      }
    }
    if at > 0 {
      builder.add_symlink(link[:at].to_owned(), link[at + 1:].to_owned())
    }
  }
  fs_write_bytes(out_path, builder.build())
  println("created \{out_path} from \{src_dir}")
}

///|

///|
/// 返回进程退出码：0 成功，1 运行/结构错误，2 用法错误。
fn run_cli(args : Array[String]) -> Int32 {
  // 各后端 argv 形状不同：wasm-gc/native 是 [程序, ...]，js 是 [node, 脚本.js, ...]
  let mut base = 1
  if base < args.length() && args[base].has_suffix(".js") {
    base += 1
  }
  if base + 1 >= args.length() {
    usage()
    return 2
  }
  let command = args[base]
  try {
    if command == "create" {
      if base + 2 >= args.length() {
        usage()
        return 2
      }
      let mut boot : String? = None
      let mut efi : String? = None
      let mut name_level = 1
      let mut rr_version = 109
      let links : Array[String] = []
      for i = base + 3; i + 1 < args.length(); i = i + 1 {
        if args[i] == "--boot" {
          boot = Some(args[i + 1])
        }
        if args[i] == "--efi" {
          efi = Some(args[i + 1])
        }
        if args[i] == "--link" {
          links.push(args[i + 1])
        }
        if args[i] == "--level" {
          let parsed = Some(@string.parse_int(args[i + 1])) catch { _ => None }
          match parsed {
            Some(level) if level >= 1 && level <= 3 => name_level = level
            _ => ()
          }
        }
        if args[i] == "--rr" {
          let parsed = Some(@string.parse_int(args[i + 1])) catch { _ => None }
          match parsed {
            Some(version) if version == 109 || version == 112 =>
              rr_version = version
            _ => ()
          }
        }
      }
      create_image(
        args[base + 1],
        args[base + 2],
        boot,
        efi,
        links,
        name_level,
        rr_version,
      )
      return 0
    }
    if command != "info" &&
      command != "ls" &&
      command != "cat" &&
      command != "extract" &&
      command != "tree" &&
      command != "extract-all" &&
      command != "verify" &&
      command != "udf-ls" &&
      command != "udf-cat" {
      usage()
      return 2
    }
    let path = if base + 2 < args.length() { args[base + 2] } else { "/" }
    let image = @mooniso.IsoImage::open(@fs.read_file_to_bytes(args[base + 1]))
    if command == "udf-ls" {
      print_udf_listing(
        @mooniso.UdfImage::open(@fs.read_file_to_bytes(args[base + 1])),
        path,
      )
    } else if command == "udf-cat" {
      let udf = @mooniso.UdfImage::open(@fs.read_file_to_bytes(args[base + 1]))
      println(@utf8.decode_lossy(udf.read_file(path)))
    } else if command == "info" {
      print_info(image)
    } else if command == "tree" {
      print_tree(image, path)
    } else if command == "verify" {
      verify_image(image)
    } else if command == "extract-all" {
      if base + 2 >= args.length() {
        usage()
        return 2
      }
      extract_all(image, "/", args[base + 2])
    } else if command == "ls" {
      print_listing(image, path)
    } else if command == "cat" {
      println(@utf8.decode_lossy(image.read_file(path)))
    } else {
      // extract 需要第三个参数：输出路径
      if base + 3 >= args.length() {
        usage()
        return 2
      }
      @fs.write_bytes_to_file(args[base + 3], image.read_file(path))
      println(
        "extracted \{path} -> \{args[base + 3]} (\{image.file_size(path)} bytes)",
      )
    }
    return 0
  } catch {
    @mooniso.IsoError::Truncated => {
      println("ERROR\ttruncated image")
      return 1
    }
    @mooniso.IsoError::BadBothEndian => {
      println("ERROR\tboth-endian fields disagree")
      return 1
    }
    @mooniso.IsoError::BadSignature => {
      println("ERROR\tnot an ISO 9660 image (missing CD001)")
      return 1
    }
    @mooniso.IsoError::BadDescriptor(code) => {
      println("ERROR\tbad volume descriptor (\{code})")
      return 1
    }
    @mooniso.IsoError::NotFound(p) => {
      println("ERROR\tno such path: \{p}")
      return 1
    }
    @mooniso.IsoError::NotDirectory(p) => {
      println("ERROR\tnot a directory: \{p}")
      return 1
    }
    @mooniso.IsoError::IsDirectory(p) => {
      println("ERROR\tis a directory: \{p}")
      return 1
    }
    @mooniso.IsoError::IsSymlink(p) => {
      println("ERROR\tis a symlink: \{p}")
      return 1
    }
    @mooniso.IsoError::HostIoError(msg) => {
      println("ERROR\tI/O: \{msg}")
      return 1
    }
    @mooniso.IsoError::BadDirectoryRecord(len) => {
      println("ERROR\tbad directory record (\{len} bytes)")
      return 1
    }
    @fs.IOError::IOError(msg) => {
      println("ERROR\tI/O: \{msg}")
      return 1
    }
    _ => {
      println("ERROR\tunexpected failure")
      return 1
    }
  }
}

///|
fn main {
  let code = run_cli(@env.args())
  if code != 0 {
    @sys.exit(code)
  }
}
