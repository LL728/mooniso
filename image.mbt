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
  for r in records {
    if !r.is_special() {
      out.push(r)
    }
  }
  out
}

///|
/// 按路径查找一条记录；路径以 / 分隔，忽略开头结尾的 / 与连续 /。
pub fn IsoImage::find_record(
  self : IsoImage,
  path : String,
) -> DirectoryRecord raise IsoError {
  let mut current = self.root
  let mut pending = false
  for segment in path.split("/") {
    let seg = segment.to_owned()
    if seg == "" {
      continue
    }
    if !current.is_dir() {
      raise NotDirectory(current.name)
    }
    let records = self.read_directory(current)
    let mut found = false
    for r in records {
      if !r.is_special() && ascii_eq_ignore_case(r.name, seg) {
        current = r
        found = true
        break
      }
    }
    if !found {
      raise NotFound(path)
    }
    pending = true
  }
  let _ = pending
  current
}
