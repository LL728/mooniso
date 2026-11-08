// IsoImage：对外入口。打开映像、按路径查目录、列目录。
//
// F1 的范围是「结构 + 目录树」：卷描述符、目录记录、路径解析、目录列举。
// 文件内容读取、Joliet、Rock Ridge、写入分别在后续功能里加。

///|
pub struct IsoImage {
  data : Bytes
  volume_id : String
  block_size : Int32
  volume_space_size : Int32
  root : DirectoryRecord
  /// Joliet 补充卷描述符的根目录；存在时默认使用它的名字（UCS-2）。
  joliet_root : DirectoryRecord?
  joliet_level : Int32
  /// 映像是否带 Rock Ridge 扩展（优先于 Joliet 使用它的名字与属性）。
  rock_ridge : Bool
}

///|
/// 打开一个 ISO 9660 映像（内存中的完整字节流）。
pub fn IsoImage::open(data : Bytes) -> IsoImage raise IsoError {
  let descriptors = scan_volume_descriptors(data)
  let mut pvd_lba = -1
  for d in descriptors {
    if d.0 == 1 {
      pvd_lba = d.1
      break
    }
  }
  if pvd_lba < 0 {
    raise BadDescriptor(0)
  }
  let pvd = parse_primary_volume_descriptor(data, pvd_lba)
  // 声明容量必须落在实际数据范围内，避免后续按越界 extent 读取
  if pvd.root.extent < 0 ||
    (pvd.root.extent + 1) * pvd.logical_block_size > data.length() {
    raise Truncated
  }
  let joliet = find_joliet_descriptor(data)
  let joliet_level = match joliet {
    Some(d) => d.level
    None => 0
  }
  let rock_ridge = detect_rock_ridge(data, pvd.logical_block_size, pvd.root)
  IsoImage::{
    data,
    volume_id: pvd.volume_id,
    block_size: pvd.logical_block_size,
    volume_space_size: pvd.volume_space_size,
    root: pvd.root,
    joliet_root: match joliet {
      Some(d) => Some(d.root)
      None => None
    },
    joliet_level,
    rock_ridge,
  }
}

///|
/// Rock Ridge 的 SP 条目只出现在根目录的「.」记录里，用它判断映像是否带 RR 扩展。
fn detect_rock_ridge(
  data : Bytes,
  block_size : Int32,
  root : DirectoryRecord,
) -> Bool raise IsoError {
  let reader = ByteReader::new(data)
  reader.seek(root.extent * block_size)
  let (first, _) = parse_directory_record_in(reader, false)
  let info = parse_rock_ridge(data, block_size, first.system_use)
  info.present
}

///|
pub fn IsoImage::volume_id(self : IsoImage) -> String {
  self.volume_id
}

///|
pub fn IsoImage::block_size(self : IsoImage) -> Int32 {
  self.block_size
}

///|
pub fn IsoImage::volume_space_size(self : IsoImage) -> Int32 {
  self.volume_space_size
}

///|
pub fn IsoImage::root(self : IsoImage) -> DirectoryRecord {
  self.root
}

///|
/// 是否使用 Joliet 名字（存在补充卷描述符时为真）。
pub fn IsoImage::uses_joliet(self : IsoImage) -> Bool {
  self.joliet_root is Some(_)
}

///|
/// El Torito 启动信息；映像不可启动时为 None。
pub fn IsoImage::boot_info(self : IsoImage) -> BootInfo? raise IsoError {
  match find_boot_catalog_lba(self.data) {
    Some(lba) => Some(parse_boot_catalog(self.data, lba))
    None => None
  }
}

///|
/// 映像是否带 Rock Ridge 扩展。
pub fn IsoImage::has_rock_ridge(self : IsoImage) -> Bool {
  self.rock_ridge
}

///|
/// Joliet 级别（1/2/3），无 Joliet 时为 0。
pub fn IsoImage::joliet_level(self : IsoImage) -> Int32 {
  self.joliet_level
}

///|
/// 当前生效的根目录：有 Joliet 用 Joliet 树，否则用主卷树。
fn IsoImage::active_root(self : IsoImage) -> DirectoryRecord {
  // Rock Ridge 的名字挂在主卷记录上，优先级高于 Joliet
  if self.rock_ridge {
    return self.root
  }
  match self.joliet_root {
    Some(root) => root
    None => self.root
  }
}

///|
/// 名字匹配：先精确，再退化为 ASCII 大小写不敏感。
fn name_matches(a : String, b : String) -> Bool {
  a == b || ascii_eq_ignore_case(a, b)
}

///|
/// ASCII 大小写不敏感比较：ISO 9660 的文件名一律大写，但用户输入通常是混合大小写。
fn ascii_eq_ignore_case(a : String, b : String) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let av = a.to_array()
  let bv = b.to_array()
  for i = 0; i < av.length(); i = i + 1 {
    let mut x = av[i].to_int()
    let mut y = bv[i].to_int()
    if x >= 97 && x <= 122 {
      x = x - 32
    }
    if y >= 97 && y <= 122 {
      y = y - 32
    }
    if x != y {
      return false
    }
  }
  true
}

///|
/// 读取一条目录记录所指向的目录数据，返回其中的全部记录（含 . 与 ..）。
fn IsoImage::read_directory(
  self : IsoImage,
  dir : DirectoryRecord,
) -> Array[DirectoryRecord] raise IsoError {
  self.read_directory_in(
    dir,
    self.uses_joliet() && !self.rock_ridge,
    self.rock_ridge,
  )
}

///|
/// 读取目录数据；`joliet` 为真时按 UCS-2 解码名字。
fn IsoImage::read_directory_in(
  self : IsoImage,
  dir : DirectoryRecord,
  joliet : Bool,
  rr : Bool,
) -> Array[DirectoryRecord] raise IsoError {
  if !dir.is_dir() {
    raise NotDirectory(dir.name)
  }
  let start = dir.extent * self.block_size
  let end = start + dir.size
  if start < 0 || end > self.data.length() {
    raise Truncated
  }
  let reader = ByteReader::new(self.data)
  reader.seek(start)
  let out : Array[DirectoryRecord] = []
  while reader.position() < end {
    let (parsed, len) = parse_directory_record_in(reader, joliet)
    let record = parsed
    if len > 0 && rr {
      // Rock Ridge：替代名字、POSIX 属性、符号链接
      let info = parse_rock_ridge(self.data, self.block_size, record.system_use)
      match info.name {
        Some(alt) => record.name = alt
        None => ()
      }
      record.posix_mode = info.mode
      record.symlink_target = info.symlink
    }
    if len == 0 {
      // 填充：跳到下一个扇区边界
      let next = (reader.position() / SECTOR_SIZE + 1) * SECTOR_SIZE
      reader.seek(if next > end { end } else { next })
    } else {
      out.push(record)
    }
  }
  out
}

///|
/// 列出目录内容（默认过滤掉 . 与 ..），保持映像里的物理顺序。
pub fn IsoImage::list_dir(
  self : IsoImage,
  path : String,
) -> Array[DirectoryRecord] raise IsoError {
  let dir = self.find_record(path)
  let records = self.read_directory(dir)
  let out : Array[DirectoryRecord] = []
  let mut i = 0
  while i < records.length() {
    let r = records[i]
    if r.is_special() {
      i += 1
      continue
    }
    if r.is_multi_extent() {
      // 多段文件在列举时合并成一条，大小取各段之和
      let mut total = r.size
      let mut j = i + 1
      while j < records.length() {
        let next = records[j]
        total = total + next.size
        let more = next.is_multi_extent()
        j += 1
        if !more {
          break
        }
      }
      out.push(DirectoryRecord::{
        extent: r.extent,
        size: total,
        flags: r.flags & 0x7F,
        name: r.name,
        date: r.date,
        system_use: r.system_use,
        posix_mode: r.posix_mode,
        symlink_target: r.symlink_target,
      })
      i = j
    } else {
      out.push(r)
      i += 1
    }
  }
  out
}

///|
/// 按路径查找「组成同一实体的连续记录」。
///
/// ISO 9660 的多段文件（flags bit 7 = 1 表示后面还有一段）用同名连续记录描述，
/// 目录永远只有一条记录。
pub fn IsoImage::find_records(
  self : IsoImage,
  path : String,
) -> Array[DirectoryRecord] raise IsoError {
  let mut current = self.active_root()
  let segments : Array[String] = []
  for segment in path.split("/") {
    let seg = segment.to_owned()
    if seg != "" {
      segments.push(seg)
    }
  }
  if segments.length() == 0 {
    return [current]
  }
  for i = 0; i < segments.length(); i = i + 1 {
    let seg = segments[i]
    if !current.is_dir() {
      raise NotDirectory(current.name)
    }
    let records = self.read_directory(current)
    let matched : Array[DirectoryRecord] = []
    let mut started = false
    for r in records {
      if r.is_special() {
        continue
      }
      if name_matches(r.name, seg) {
        matched.push(r)
        started = true
      } else if started {
        break
      }
    }
    if matched.length() == 0 {
      raise NotFound(path)
    }
    let is_last = i == segments.length() - 1
    if is_last {
      return matched
    }
    if matched.length() > 1 {
      raise NotDirectory(seg)
    }
    current = matched[0]
  }
  [current]
}

///|
/// 按路径查找一条记录（多段文件返回第一段）。
pub fn IsoImage::find_record(
  self : IsoImage,
  path : String,
) -> DirectoryRecord raise IsoError {
  self.find_records(path)[0]
}

///|
/// 读取文件内容：多段文件按记录顺序拼接，目录以 IsDirectory 失败。
/// 全程做边界检查，越界一律 Truncated，不会读到映像之外。
pub fn IsoImage::read_file(
  self : IsoImage,
  path : String,
) -> Bytes raise IsoError {
  let records = self.find_records(path)
  if records[0].is_dir() {
    raise IsDirectory(path)
  }
  if records[0].is_symlink() {
    raise IsSymlink(path)
  }
  let mut total = 0
  for r in records {
    total = total + r.size
  }
  let out = FixedArray::make(total, b'\x00')
  let mut written = 0
  for r in records {
    let start = r.extent * self.block_size
    if r.size < 0 || start < 0 || start + r.size > self.data.length() {
      raise Truncated
    }
    for i = 0; i < r.size; i = i + 1 {
      out[written + i] = self.data[start + i]
    }
    written = written + r.size
  }
  Bytes::from_array(out[:])
}

///|
/// 遍历结果的一项。
pub struct WalkEntry {
  path : String
  is_dir : Bool
  is_symlink : Bool
  size : Int32
}

///|
/// 递归遍历目录树（路径形如 /Docs/note.md，按物理顺序）。
pub fn IsoImage::walk(
  self : IsoImage,
  path : String,
) -> Array[WalkEntry] raise IsoError {
  let out : Array[WalkEntry] = []
  self.walk_into(path, "", out)
  out
}

///|
fn IsoImage::walk_into(
  self : IsoImage,
  path : String,
  prefix : String,
  out : Array[WalkEntry],
) -> Unit raise IsoError {
  for entry in self.list_dir(path) {
    let child = prefix + "/" + entry.name
    out.push(WalkEntry::{
      path: child,
      is_dir: entry.is_dir(),
      is_symlink: entry.is_symlink(),
      size: entry.size,
    })
    if entry.is_dir() {
      self.walk_into(child, child, out)
    }
  }
}

///|
/// 结构校验结果。
pub struct ValidationReport {
  directories : Int32
  files : Int32
  symlinks : Int32
  total_bytes : Int32
  problems : Array[String]
}

///|
/// 遍历整棵目录树做结构校验：记录能否解析、extent 是否越界、文件能否读完。
/// 返回全部问题而不是遇错即停，方便一次性给出体检结论。
pub fn IsoImage::validate(self : IsoImage) -> ValidationReport {
  let problems : Array[String] = []
  let mut directories = 0
  let mut files = 0
  let mut symlinks = 0
  let mut total_bytes = 0
  let stack : Array[String] = ["/"]
  while stack.length() > 0 {
    let dir = stack.pop().unwrap()
    directories = directories + 1
    let entries = self.list_dir(dir) catch {
      _ => {
        problems.push("无法列出目录: " + dir)
        continue
      }
    }
    for entry in entries {
      let child = if dir == "/" {
        "/" + entry.name
      } else {
        dir + "/" + entry.name
      }
      if entry.is_dir() {
        stack.push(child)
      } else if entry.is_symlink() {
        // 符号链接没有自身内容，只计数
        symlinks = symlinks + 1
      } else {
        files = files + 1
        total_bytes = total_bytes + entry.size
        let bytes = Some(self.read_file(child)) catch { _ => None }
        match bytes {
          Some(data) =>
            if data.length() != entry.size {
              problems.push("读取长度不符: " + child)
            }
          None => problems.push("读取失败: " + child)
        }
      }
    }
  }
  ValidationReport::{ directories, files, symlinks, total_bytes, problems, }
}

///|
/// 文件大小（多段文件为各段之和）。
pub fn IsoImage::file_size(
  self : IsoImage,
  path : String,
) -> Int32 raise IsoError {
  let mut total = 0
  for r in self.find_records(path) {
    total = total + r.size
  }
  total
}
