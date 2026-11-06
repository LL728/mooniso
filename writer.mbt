// ISO 9660 映像生成（写入侧）。
//
// 设计：先把「目录树」规整成平坦表，再按 ECMA-119 的布局顺序分配逻辑块：
//   16..        卷描述符（PVD / 可选 Joliet SVD / 结束符）
//   之后        L、M 路径表（Joliet 时各再一对）
//   之后        每个目录的数据块（ISO 树一份，Joliet 树一份）
//   最后        文件内容
// 目录记录里的名字按三套并存：ISO 9660 level 1（8.3 + ;1）、Joliet（UCS-2 原名）、
// Rock Ridge（NM 保存原名，PX 保存 POSIX 权限）。

///|
pub struct IsoBuilder {
  mut volume_id : String
  mut joliet : Bool
  mut rock_ridge : Bool
  dirs : Array[String]
  files : Array[(String, Bytes)]
}

///|
pub fn IsoBuilder::new() -> IsoBuilder {
  {
    volume_id: "MOONISO",
    joliet: true,
    rock_ridge: true,
    dirs: ["/"],
    files: [],
  }
}

///|
pub fn IsoBuilder::volume_id(self : IsoBuilder, id : String) -> Unit {
  self.volume_id = id
}

///|
pub fn IsoBuilder::joliet(self : IsoBuilder, enable : Bool) -> Unit {
  self.joliet = enable
}

///|
pub fn IsoBuilder::rock_ridge(self : IsoBuilder, enable : Bool) -> Unit {
  self.rock_ridge = enable
}

///|
/// 规整路径：保证以 / 开头、去掉结尾 /、折叠重复 /。
pub fn normalize_path(path : String) -> String {
  let parts : Array[String] = []
  for segment in path.split("/") {
    let seg = segment.to_owned()
    if seg != "" && seg != "." {
      parts.push(seg)
    }
  }
  let mut out = ""
  for part in parts {
    out = out + "/" + part
  }
  if out == "" {
    "/"
  } else {
    out
  }
}

///|
fn last_slash(path : String) -> Int32 {
  let chars = path.to_array()
  let mut result = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i].to_int() == 47 {
      result = i
    }
  }
  result
}

///|
fn parent_of(path : String) -> String {
  let normalized = normalize_path(path)
  if normalized == "/" {
    return "/"
  }
  let idx = last_slash(normalized)
  if idx <= 0 {
    "/"
  } else {
    normalized[:idx].to_owned()
  }
}

///|
fn base_of(path : String) -> String {
  let normalized = normalize_path(path)
  let idx = last_slash(normalized)
  normalized[idx + 1:].to_owned()
}

///|
/// 把名字转成 ISO 9660 level 1 的 8.3 形式（目录不带扩展名与版本号）。
fn iso_level1(name : String, is_dir : Bool, used : Array[String]) -> String {
  let mut base = ""
  let mut ext = ""
  let mut in_ext = false
  for c in name.to_array() {
    let code = c.to_int()
    let mapped = if code >= 97 && code <= 122 {
      Int32::unsafe_to_char(code - 32)
    } else if (code >= 65 && code <= 90) ||
      (code >= 48 && code <= 57) ||
      code == 95 {
      c
    } else if code == 46 && !is_dir {
      in_ext = true
      continue
    } else {
      Int32::unsafe_to_char(95) // 其它字符统一成下划线
    }
    if in_ext {
      ext = ext + mapped.to_string()
    } else {
      base = base + mapped.to_string()
    }
  }
  let mut trimmed_base = if base.length() > 8 {
    base[:8].to_owned()
  } else {
    base
  }
  let trimmed_ext = if ext.length() > 3 { ext[:3].to_owned() } else { ext }
  if trimmed_base == "" {
    trimmed_base = if is_dir { "DIR" } else { "FILE" }
  }
  let mut candidate = if is_dir || trimmed_ext == "" {
    trimmed_base
  } else {
    trimmed_base + "." + trimmed_ext
  }
  // 同目录内去重：ISO 9660 要求名字唯一
  let mut suffix = 0
  while used.contains(candidate) {
    suffix = suffix + 1
    let tag = suffix.to_string()
    let keep = if trimmed_base.length() + tag.length() > 8 {
      8 - tag.length()
    } else {
      trimmed_base.length()
    }
    let stem = trimmed_base[:keep].to_owned() + tag
    candidate = if is_dir || trimmed_ext == "" {
      stem
    } else {
      stem + "." + trimmed_ext
    }
  }
  used.push(candidate)
  if is_dir {
    candidate
  } else {
    candidate + ";1"
  }
}

///|
/// 目录记录里的名字字段（ASCII 大写）。
fn ascii_bytes(text : String) -> Bytes {
  let out = FixedArray::make(text.length(), b'\x00')
  let chars = text.to_array()
  for i = 0; i < chars.length(); i = i + 1 {
    out[i] = chars[i].to_int().to_byte()
  }
  Bytes::from_array(out[:])
}

///|
/// Joliet 名字（UCS-2 大端）。
fn ucs2be_bytes(text : String) -> Bytes {
  let chars = text.to_array()
  let out = FixedArray::make(chars.length() * 2, b'\x00')
  for i = 0; i < chars.length(); i = i + 1 {
    let code = chars[i].to_int()
    out[i * 2] = ((code >> 8) & 0xFF).to_byte()
    out[i * 2 + 1] = (code & 0xFF).to_byte()
  }
  Bytes::from_array(out[:])
}

///|
fn both16(value : Int32) -> Bytes {
  let out = FixedArray::make(4, b'\x00')
  out[0] = (value & 0xFF).to_byte()
  out[1] = ((value >> 8) & 0xFF).to_byte()
  out[2] = ((value >> 8) & 0xFF).to_byte()
  out[3] = (value & 0xFF).to_byte()
  Bytes::from_array(out[:])
}

///|
fn both32(value : Int32) -> Bytes {
  let out = FixedArray::make(8, b'\x00')
  out[0] = (value & 0xFF).to_byte()
  out[1] = ((value >> 8) & 0xFF).to_byte()
  out[2] = ((value >> 16) & 0xFF).to_byte()
  out[3] = ((value >> 24) & 0xFF).to_byte()
  out[4] = ((value >> 24) & 0xFF).to_byte()
  out[5] = ((value >> 16) & 0xFF).to_byte()
  out[6] = ((value >> 8) & 0xFF).to_byte()
  out[7] = (value & 0xFF).to_byte()
  Bytes::from_array(out[:])
}

///|
fn concat_bytes(parts : Array[Bytes]) -> Bytes {
  let mut total = 0
  for p in parts {
    total = total + p.length()
  }
  let out = FixedArray::make(total, b'\x00')
  let mut at = 0
  for p in parts {
    for i = 0; i < p.length(); i = i + 1 {
      out[at + i] = p[i]
    }
    at = at + p.length()
  }
  Bytes::from_array(out[:])
}

///|
/// 生成一条目录记录。
///
/// `name_bytes` 是记录里的名字字段（ISO 为 ASCII，Joliet 为 UCS-2），
/// `susp` 是 Rock Ridge 的 system use area（没有则传空）。
fn make_dir_record(
  extent : Int32,
  size : Int32,
  flags : Int32,
  name_bytes : Bytes,
  susp : Bytes,
) -> Bytes {
  let fixed = FixedArray::make(33, b'\x00')
  fixed[1] = b'\x00' // 扩展属性长度
  let extent_bytes = both32(extent)
  for i = 0; i < 8; i = i + 1 {
    fixed[2 + i] = extent_bytes[i]
  }
  let size_bytes = both32(size)
  for i = 0; i < 8; i = i + 1 {
    fixed[10 + i] = size_bytes[i]
  }
  // 记录时间：2026-01-02 03:04:05 UTC
  fixed[18] = b'\x7E'
  fixed[19] = b'\x01'
  fixed[20] = b'\x02'
  fixed[21] = b'\x03'
  fixed[22] = b'\x04'
  fixed[23] = b'\x05'
  fixed[24] = b'\x00'
  fixed[25] = flags.to_byte()
  let seq = both16(1)
  for i = 0; i < 4; i = i + 1 {
    fixed[28 + i] = seq[i]
  }
  fixed[32] = name_bytes.length().to_byte()
  let name = name_bytes
  let padding = if name_bytes.length() % 2 == 0 {
    Bytes::from_array([b'\x00'][:])
  } else {
    Bytes::new(0)
  }
  let total = concat_bytes([Bytes::from_array(fixed[:]), name, padding, susp])
  let out = FixedArray::make(total.length(), b'\x00')
  for i = 0; i < total.length(); i = i + 1 {
    out[i] = total[i]
  }
  out[0] = total.length().to_byte()
  Bytes::from_array(out[:])
}

///|
/// Rock Ridge 的 NM + PX 条目。
fn rr_susp(name : String, mode : Int32) -> Bytes {
  let rr = Bytes::from_array([b'R', b'R', b'\x05', b'\x01', b'\x01'][:])
  // Rock Ridge 的 NM 按惯例是 UTF-8 字节，不能用 ASCII 截断
  let nm_bytes = @utf8.encode(name)
  let nm = concat_bytes([
    Bytes::from_array(
      [b'N', b'M', (nm_bytes.length() + 5).to_byte(), b'\x01', b'\x00'][:],
    ),
    nm_bytes,
  ])
  // PX 用 4 个字段（mode/nlink/uid/gid）共 32 字节 = RR 1.09 的形态
  let px_body = concat_bytes([both32(mode), both32(1), both32(0), both32(0)])
  let px = concat_bytes([
    Bytes::from_array(
      [b'P', b'X', (px_body.length() + 4).to_byte(), b'\x01'][:],
    ),
    px_body,
  ])
  concat_bytes([rr, nm, px])
}

///|
/// 根目录「.」记录里的 SP + ER，声明本映像带 Rock Ridge。
fn rr_sp_er() -> Bytes {
  let sp = Bytes::from_array(
    [b'S', b'P', b'\x07', b'\x01', b'\xBE', b'\xEF', b'\x00'][:],
  )
  let id = ascii_bytes("RRIP_1991A")
  let desc = ascii_bytes("THE ROCK RIDGE INTERCHANGE PROTOCOL")
  // ER：4 个长度/版本字节 + 扩展名 + 描述 + 来源
  let body = concat_bytes([
    Bytes::from_array(
      [id.length().to_byte(), desc.length().to_byte(), b'\x00', b'\x01'][:],
    ),
    id,
    desc,
  ])
  let er = concat_bytes([
    Bytes::from_array([b'E', b'R', (body.length() + 4).to_byte(), b'\x01'][:]),
    body,
  ])
  concat_bytes([sp, er])
}

///|
/// 按 ECMA-119 要求把若干记录打包成一个或多个逻辑块（记录不得跨扇区）。
fn pack_records(records : Array[Bytes], sector : Int32) -> Bytes {
  let out = FixedArray::make(records.length() * 256 + sector, b'\x00')
  let mut pos = 0
  for rec in records {
    if pos % sector + rec.length() > sector {
      pos = (pos / sector + 1) * sector
    }
    for i = 0; i < rec.length(); i = i + 1 {
      out[pos + i] = rec[i]
    }
    pos = pos + rec.length()
  }
  let size = if pos % sector == 0 { pos } else { (pos / sector + 1) * sector }
  let trimmed = FixedArray::make(size, b'\x00')
  for i = 0; i < size; i = i + 1 {
    trimmed[i] = out[i]
  }
  Bytes::from_array(trimmed[:])
}

///|
fn ceil_sectors(size : Int32, sector : Int32) -> Int32 {
  if size <= 0 {
    1
  } else {
    (size + sector - 1) / sector
  }
}

///|
/// 生成过程中的目录项。
priv struct OutDir {
  name : String
  mut iso_name : String
  parent : Int32
  mut lba : Int32
  mut size : Int32
  mut data : Bytes
}

///|
/// 生成过程中的文件项。
priv struct OutFile {
  name : String
  mut iso_name : String
  dir : Int32
  mut lba : Int32
  size : Int32
  data : Bytes
}

///|
fn index_of(arr : Array[String], value : String) -> Int32 {
  for i = 0; i < arr.length(); i = i + 1 {
    if arr[i] == value {
      return i
    }
  }
  -1
}

///|
/// 按名字插入排序（ISO 9660 要求目录记录按名字升序）。
fn sort_names(names : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for name in names {
    let mut at = out.length()
    for i = 0; i < out.length(); i = i + 1 {
      if name < out[i] {
        at = i
        break
      }
    }
    out.insert(at, name)
  }
  out
}

///|
pub fn IsoBuilder::add_directory(self : IsoBuilder, path : String) -> Unit {
  let normalized = normalize_path(path)
  if index_of(self.dirs, normalized) < 0 {
    // 先补齐所有父目录
    let parent = parent_of(normalized)
    if parent != normalized && index_of(self.dirs, parent) < 0 {
      self.add_directory(parent)
    }
    self.dirs.push(normalized)
  }
}

///|
pub fn IsoBuilder::add_file(
  self : IsoBuilder,
  path : String,
  data : Bytes,
) -> Unit {
  let normalized = normalize_path(path)
  let parent = parent_of(normalized)
  if index_of(self.dirs, parent) < 0 {
    self.add_directory(parent)
  }
  self.files.push((normalized, data))
}

///|
/// 生成完整的 ISO 9660 映像字节。
pub fn IsoBuilder::build(self : IsoBuilder) -> Bytes raise IsoError {
  let sector = SECTOR_SIZE
  let dirs : Array[OutDir] = [
    OutDir::{
      name: "",
      iso_name: "",
      parent: -1,
      lba: 0,
      size: 0,
      data: Bytes::new(0),
    },
  ]
  let paths : Array[String] = ["/"]
  let ordered = sort_names(self.dirs)
  for path in ordered {
    if path == "/" {
      continue
    }
    let parent = index_of(paths, parent_of(path))
    if parent < 0 {
      raise BadDescriptor(0)
    }
    paths.push(path)
    dirs.push(OutDir::{
      name: base_of(path),
      iso_name: "",
      parent,
      lba: 0,
      size: 0,
      data: Bytes::new(0),
    })
  }
  let files : Array[OutFile] = []
  for entry in self.files {
    let (path, data) = entry
    let directory = index_of(paths, parent_of(path))
    if directory < 0 {
      raise BadDescriptor(0)
    }
    files.push(OutFile::{
      name: base_of(path),
      iso_name: "",
      dir: directory,
      lba: 0,
      size: data.length(),
      data,
    })
  }
  // 每个目录内部各自去重地分配 ISO 9660 level 1 名字
  for d = 0; d < dirs.length(); d = d + 1 {
    let used : Array[String] = []
    for i = 0; i < dirs.length(); i = i + 1 {
      if dirs[i].parent == d {
        dirs[i].iso_name = iso_level1(dirs[i].name, true, used)
      }
    }
    for i = 0; i < files.length(); i = i + 1 {
      if files[i].dir == d {
        files[i].iso_name = iso_level1(files[i].name, false, used)
      }
    }
  }
  // 先按占位 extent 生成一遍，得到每个目录数据块的大小
  for d = 0; d < dirs.length(); d = d + 1 {
    let records = build_dir_records(d, dirs, files, false, false, [])
    dirs[d].data = pack_records(records, sector)
    dirs[d].size = dirs[d].data.length()
  }
  // 布局：卷描述符 -> 路径表 -> ISO 目录 -> Joliet 目录 -> 文件内容
  let terminator_lba = 16 + 1 + (if self.joliet { 1 } else { 0 })
  let mut cursor = terminator_lba + 1
  let iso_l_pt = cursor
  cursor += 1
  let iso_m_pt = cursor
  cursor += 1
  let mut joliet_l_pt = 0
  let mut joliet_m_pt = 0
  if self.joliet {
    joliet_l_pt = cursor
    cursor += 1
    joliet_m_pt = cursor
    cursor += 1
  }
  for d = 0; d < dirs.length(); d = d + 1 {
    dirs[d].lba = cursor
    cursor += ceil_sectors(dirs[d].size, sector)
  }
  let joliet_dirs : Array[OutDir] = []
  if self.joliet {
    for d = 0; d < dirs.length(); d = d + 1 {
      let records = build_dir_records(d, dirs, files, true, false, [])
      let data = pack_records(records, sector)
      joliet_dirs.push(OutDir::{
        name: dirs[d].name,
        iso_name: dirs[d].iso_name,
        parent: dirs[d].parent,
        lba: cursor,
        size: data.length(),
        data,
      })
      cursor += ceil_sectors(data.length(), sector)
    }
  }
  for f = 0; f < files.length(); f = f + 1 {
    files[f].lba = cursor
    cursor += ceil_sectors(files[f].size, sector)
  }
  let total_sectors = cursor
  // 用真实 extent 重新生成目录数据
  for d = 0; d < dirs.length(); d = d + 1 {
    dirs[d].data = pack_records(
      build_dir_records(d, dirs, files, false, self.rock_ridge, []),
      sector,
    )
  }
  if self.joliet {
    for d = 0; d < joliet_dirs.length(); d = d + 1 {
      joliet_dirs[d].data = pack_records(
        build_dir_records(d, dirs, files, true, false, joliet_dirs),
        sector,
      )
    }
  }
  let image = FixedArray::make(total_sectors * sector, b'\x00')
  let write_at = fn(lba : Int32, data : Bytes) -> Unit {
    for i = 0; i < data.length(); i = i + 1 {
      image[lba * sector + i] = data[i]
    }
  }
  for d = 0; d < dirs.length(); d = d + 1 {
    write_at(dirs[d].lba, dirs[d].data)
  }
  if self.joliet {
    for d = 0; d < joliet_dirs.length(); d = d + 1 {
      write_at(joliet_dirs[d].lba, joliet_dirs[d].data)
    }
  }
  for f = 0; f < files.length(); f = f + 1 {
    write_at(files[f].lba, files[f].data)
  }
  // 路径表
  let iso_table = path_table_bytes(dirs, false, false)
  write_at(iso_l_pt, iso_table)
  write_at(iso_m_pt, path_table_bytes(dirs, true, false))
  if self.joliet {
    write_at(joliet_l_pt, path_table_bytes(joliet_dirs, false, true))
    write_at(joliet_m_pt, path_table_bytes(joliet_dirs, true, true))
  }
  // 卷描述符
  write_at(
    16,
    make_pvd(
      self,
      dirs[0],
      iso_table.length(),
      iso_l_pt,
      iso_m_pt,
      total_sectors,
    ),
  )
  if self.joliet {
    write_at(
      17,
      make_svd(
        self,
        joliet_dirs[0],
        path_table_bytes(joliet_dirs, false, true).length(),
        joliet_l_pt,
        joliet_m_pt,
      ),
    )
  }
  write_at(terminator_lba, terminator_sector())
  Bytes::from_array(image[:])
}

///|
/// 生成某个目录的记录集合。
///
/// `joliet_tree` 为真时用 Joliet 的目录 extent 与 UCS-2 名字；
/// 否则用 ISO 树，并在 rr 为真时附上 Rock Ridge 条目。
fn build_dir_records(
  d : Int32,
  dirs : Array[OutDir],
  files : Array[OutFile],
  joliet_tree : Bool,
  rr : Bool,
  joliet_dirs : Array[OutDir],
) -> Array[Bytes] {
  let extent_of = fn(index : Int32) -> Int32 {
    if joliet_tree && index < joliet_dirs.length() {
      joliet_dirs[index].lba
    } else {
      dirs[index].lba
    }
  }
  let size_of = fn(index : Int32) -> Int32 {
    if joliet_tree && index < joliet_dirs.length() {
      joliet_dirs[index].size
    } else {
      dirs[index].size
    }
  }
  let self_extent = extent_of(d)
  let self_size = size_of(d)
  let parent = dirs[d].parent
  let parent_index = if parent < 0 { d } else { parent }
  let records : Array[Bytes] = []
  // "."（根目录额外带 SP + ER）
  let self_susp = if rr && d == 0 { rr_sp_er() } else { Bytes::new(0) }
  records.push(
    make_dir_record(
      self_extent,
      self_size,
      2,
      Bytes::from_array([b'\x00'][:]),
      self_susp,
    ),
  )
  records.push(
    make_dir_record(
      extent_of(parent_index),
      size_of(parent_index),
      2,
      Bytes::from_array([b'\x01'][:]),
      Bytes::new(0),
    ),
  )
  // 子目录 + 文件，按名字升序
  let keys : Array[String] = []
  let kinds : Array[Int32] = []
  let indexes : Array[Int32] = []
  for i = 0; i < dirs.length(); i = i + 1 {
    if dirs[i].parent == d && i != 0 {
      keys.push(if joliet_tree { dirs[i].name } else { dirs[i].iso_name })
      kinds.push(0)
      indexes.push(i)
    }
  }
  for i = 0; i < files.length(); i = i + 1 {
    if files[i].dir == d {
      keys.push(if joliet_tree { files[i].name } else { files[i].iso_name })
      kinds.push(1)
      indexes.push(i)
    }
  }
  // 简单插入排序，保持记录升序
  let order : Array[Int32] = []
  for i = 0; i < keys.length(); i = i + 1 {
    let mut at = order.length()
    for j = 0; j < order.length(); j = j + 1 {
      if keys[i] < keys[order[j]] {
        at = j
        break
      }
    }
    order.insert(at, i)
  }
  for k in order {
    let index = indexes[k]
    if kinds[k] == 0 {
      let name = if joliet_tree {
        ucs2be_bytes(dirs[index].name)
      } else {
        ascii_bytes(dirs[index].iso_name)
      }
      let susp = if rr {
        rr_susp(dirs[index].name, 0o040755)
      } else {
        Bytes::new(0)
      }
      records.push(
        make_dir_record(extent_of(index), size_of(index), 2, name, susp),
      )
    } else {
      let name = if joliet_tree {
        ucs2be_bytes(files[index].name + ";1")
      } else {
        ascii_bytes(files[index].iso_name)
      }
      let flags = if files[index].size > 0 { 0 } else { 0 }
      let susp = if rr {
        rr_susp(files[index].name, 0o100644)
      } else {
        Bytes::new(0)
      }
      records.push(
        make_dir_record(files[index].lba, files[index].size, flags, name, susp),
      )
    }
  }
  records
}

///|
/// 路径表要求的顺序：根在前，其后按「父目录号、名字」升序（这里用 BFS 实现）。
fn path_table_order(dirs : Array[OutDir]) -> Array[Int32] {
  let order : Array[Int32] = [0]
  let mut at = 0
  while at < order.length() {
    let current = order[at]
    at += 1
    let children : Array[Int32] = []
    for i = 1; i < dirs.length(); i = i + 1 {
      if dirs[i].parent == current && !order.contains(i) {
        children.push(i)
      }
    }
    // 按名字排序后追加
    let names : Array[String] = []
    for c in children {
      names.push(dirs[c].iso_name)
    }
    let sorted = sort_names(names)
    for name in sorted {
      for c in children {
        if dirs[c].iso_name == name && !order.contains(c) {
          order.push(c)
          break
        }
      }
    }
  }
  order
}

///|
/// 生成路径表（`big_endian` 为真时输出 M 表）。
fn path_table_bytes(
  dirs : Array[OutDir],
  big_endian : Bool,
  joliet : Bool,
) -> Bytes {
  let order = path_table_order(dirs)
  let parts : Array[Bytes] = []
  for position = 0; position < order.length(); position = position + 1 {
    let index = order[position]
    let dir = dirs[index]
    let is_root = index == 0
    let name = if is_root {
      Bytes::from_array([b'\x00'][:])
    } else if joliet {
      // Joliet 路径表同样使用 UCS-2 名字
      ucs2be_bytes(dir.name)
    } else {
      ascii_bytes(dir.iso_name)
    }
    let extent = both32(dir.lba)
    let parent_number = if is_root {
      1
    } else {
      let p = dir.parent
      let mut number = 1
      for i = 0; i < order.length(); i = i + 1 {
        if order[i] == p {
          number = i + 1
          break
        }
      }
      number
    }
    let parent = both16(parent_number)
    let record = concat_bytes([
      Bytes::from_array([name.length().to_byte(), b'\x00'][:]),
      if big_endian {
        Bytes::from_array(
          [extent[4], extent[5], extent[6], extent[7], parent[2], parent[3]][:],
        )
      } else {
        Bytes::from_array(
          [extent[0], extent[1], extent[2], extent[3], parent[0], parent[1]][:],
        )
      },
      name,
    ])
    let padded = if record.length() % 2 == 0 {
      record
    } else {
      concat_bytes([record, Bytes::from_array([b'\x00'][:])])
    }
    parts.push(padded)
  }
  concat_bytes(parts)
}

///|
fn descriptor_base(
  kind : Int32,
  volume_id : String,
  total_sectors : Int32,
  table_size : Int32,
  l_table : Int32,
  m_table : Int32,
  root : OutDir,
  rr : Bool,
  joliet : Bool,
) -> Bytes {
  let sector = FixedArray::make(SECTOR_SIZE, b'\x00')
  sector[0] = kind.to_byte()
  let magic = ascii_bytes("CD001")
  for i = 0; i < 5; i = i + 1 {
    sector[1 + i] = magic[i]
  }
  sector[6] = b'\x01'
  for i = 8; i < 40; i = i + 1 {
    sector[i] = b' '
  }
  let id_bytes = if joliet {
    ucs2be_bytes(volume_id)
  } else {
    ascii_bytes(volume_id)
  }
  for i = 0; i < id_bytes.length() && i < 32; i = i + 1 {
    sector[40 + i] = id_bytes[i]
  }
  for i = 40 + id_bytes.length(); i < 72; i = i + 1 {
    sector[i] = b' '
  }
  let space = both32(total_sectors)
  for i = 0; i < 8; i = i + 1 {
    sector[80 + i] = space[i]
  }
  let set_size = both16(1)
  for i = 0; i < 4; i = i + 1 {
    sector[120 + i] = set_size[i]
  }
  for i = 0; i < 4; i = i + 1 {
    sector[124 + i] = set_size[i]
  }
  let block = both16(SECTOR_SIZE)
  for i = 0; i < 4; i = i + 1 {
    sector[128 + i] = block[i]
  }
  let size = both32(table_size)
  for i = 0; i < 8; i = i + 1 {
    sector[132 + i] = size[i]
  }
  sector[140] = (l_table & 0xFF).to_byte()
  sector[141] = ((l_table >> 8) & 0xFF).to_byte()
  sector[142] = ((l_table >> 16) & 0xFF).to_byte()
  sector[143] = ((l_table >> 24) & 0xFF).to_byte()
  sector[148] = ((m_table >> 24) & 0xFF).to_byte()
  sector[149] = ((m_table >> 16) & 0xFF).to_byte()
  sector[150] = ((m_table >> 8) & 0xFF).to_byte()
  sector[151] = (m_table & 0xFF).to_byte()
  if joliet {
    // Joliet level 3 的转义序列 %/E
    sector[88] = b'%'
    sector[89] = b'/'
    sector[90] = b'E'
  }
  let root_record = make_dir_record(
    root.lba,
    root.size,
    2,
    Bytes::from_array([b'\x00'][:]),
    if rr {
      rr_sp_er()
    } else {
      Bytes::new(0)
    },
  )
  for i = 0; i < root_record.length(); i = i + 1 {
    sector[156 + i] = root_record[i]
  }
  for i = 190; i < 318; i = i + 1 {
    sector[i] = b' '
  }
  for i = 318; i < 446; i = i + 1 {
    sector[i] = b' '
  }
  for i = 446; i < 574; i = i + 1 {
    sector[i] = b' '
  }
  for i = 574; i < 702; i = i + 1 {
    sector[i] = b' '
  }
  for start in [702, 739, 776] {
    for i = start; i < start + 37; i = i + 1 {
      sector[i] = b' '
    }
  }
  for start in [813, 830, 847, 864] {
    for i = start; i < start + 16; i = i + 1 {
      sector[i] = b'0'
    }
  }
  sector[881] = b'\x01'
  Bytes::from_array(sector[:])
}

///|
fn make_pvd(
  builder : IsoBuilder,
  root : OutDir,
  table_size : Int32,
  l_table : Int32,
  m_table : Int32,
  total_sectors : Int32,
) -> Bytes {
  descriptor_base(
    1,
    builder.volume_id,
    total_sectors,
    table_size,
    l_table,
    m_table,
    root,
    builder.rock_ridge,
    false,
  )
}

///|
fn make_svd(
  builder : IsoBuilder,
  root : OutDir,
  table_size : Int32,
  l_table : Int32,
  m_table : Int32,
) -> Bytes {
  descriptor_base(
    2,
    builder.volume_id,
    0,
    table_size,
    l_table,
    m_table,
    root,
    false,
    true,
  )
}

///|
fn terminator_sector() -> Bytes {
  let sector = FixedArray::make(SECTOR_SIZE, b'\x00')
  sector[0] = b'\xFF'
  let magic = ascii_bytes("CD001")
  for i = 0; i < 5; i = i + 1 {
    sector[1 + i] = magic[i]
  }
  sector[6] = b'\x01'
  Bytes::from_array(sector[:])
}
