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
  IsoImage::{
    data,
    volume_id: pvd.volume_id,
    block_size: pvd.logical_block_size,
    volume_space_size: pvd.volume_space_size,
    root: pvd.root,
  }
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
    let (record, len) = parse_directory_record(reader)
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
  let mut current = self.root
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
      if ascii_eq_ignore_case(r.name, seg) {
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
