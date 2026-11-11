// UDF（ECMA-167 / ISO 13346）读取。
//
// 路径：Anchor Volume Descriptor Pointer（第 256 块）-> 描述符序列
//   -> Partition Descriptor（分区起点）+ Logical Volume Descriptor（块大小、File Set 位置）
//   -> File Set Descriptor（根目录 ICB）-> File Entry（分配描述符）-> 目录 FID / 文件内容
//
// 范围：UDF 1.02（ECMA-167 第 2 版）单分区只读映像。
//
// 不覆盖的布局一律**明确报 UnsupportedLayout**，不做静默误读：
//   - 元数据分区（UDF 2.50+ 用它将文件条目当作可重定位元数据，是 2.50/2.60 的必需寻址层）
//   - 虚拟分区 / VAS（多区段写入的 VAT）
//   - Sparable 分区（可重写介质的备用块映射）
//   - 扩展文件条目（UDF 2.00+ 的 tag 266）

///|
/// 分区映射的类型标签：type0 / type1 / metadata / virtual / sparable。
fn partition_map_kinds(lvd : Bytes) -> Array[String] {
  let out : Array[String] = []
  let count = read_le32(lvd, 268)
  let table_len = read_le32(lvd, 264)
  let end = if 440 + table_len > lvd.length() {
    lvd.length()
  } else {
    440 + table_len
  }
  let mut at = 440
  let mut seen = 0
  while seen < count && at + 2 <= end {
    let kind = lvd[at].to_uint().reinterpret_as_int()
    let size = lvd[at + 1].to_uint().reinterpret_as_int()
    if size < 2 || at + size > end {
      break
    }
    if kind == 1 {
      out.push("type1")
    } else if kind == 2 {
      // Type 2 映射的载荷是 EntityID：flags(1) + identifier(23) + suffix(8)
      let ident = sub_bytes(lvd, at + 3, at + 26)
      let text = ascii_of(ident)
      if text == "*UDF Metadata Partition" {
        out.push("metadata")
      } else if text == "*UDF Virtual Partition" {
        out.push("virtual")
      } else if text == "*UDF Sparable Partition" {
        out.push("sparable")
      } else {
        out.push("type2")
      }
    } else {
      out.push("type0")
    }
    at = at + size
    seen = seen + 1
  }
  out
}

///|
/// 把定长 ASCII 字段转成字符串（截掉 NUL 与尾部空格）。
fn ascii_of(raw : Bytes) -> String {
  let mut out = ""
  for i = 0; i < raw.length(); i = i + 1 {
    let code = raw[i].to_uint().reinterpret_as_int()
    if code == 0 {
      break
    }
    out = out + Int32::unsafe_to_char(code).to_string()
  }
  out
}

///|
/// UDF 描述符公共头（tag），16 字节。
priv struct UdfTag {
  id : Int32
  checksum_ok : Bool
}

///|
fn read_le16(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_uint().reinterpret_as_int() |
  (data[offset + 1].to_uint().reinterpret_as_int() << 8)
}

///|
fn read_le32(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_uint().reinterpret_as_int() |
  (data[offset + 1].to_uint().reinterpret_as_int() << 8) |
  (data[offset + 2].to_uint().reinterpret_as_int() << 16) |
  (data[offset + 3].to_uint().reinterpret_as_int() << 24)
}

///|

///|
/// UDF 的信息长度是 64 位；本实现只支持 4 GiB 以内的文件，超出返回 -1。
fn read_length64(data : Bytes, offset : Int32) -> Int32 {
  let hi = read_le32(data, offset + 4)
  let lo = read_le32(data, offset)
  if hi != 0 {
    -1
  } else {
    lo
  }
}

///|
/// 解析并校验 tag：校验和 = 除第 4 字节外全部 16 字节之和（模 256）。
fn parse_tag(data : Bytes, offset : Int32) -> UdfTag {
  let mut sum = 0
  for i = 0; i < 16; i = i + 1 {
    if i != 4 {
      sum = sum + data[offset + i].to_uint().reinterpret_as_int()
    }
  }
  UdfTag::{
    id: read_le16(data, offset),
    checksum_ok: sum % 256 == data[offset + 4].to_uint().reinterpret_as_int(),
  }
}

///|
/// 长分配描述符（long_ad）：长度、逻辑块号、分区引用号。
pub struct UdfExtent {
  length : Int32
  location : Int32
  partition : Int32
}

///|
fn read_long_ad(data : Bytes, offset : Int32) -> UdfExtent {
  UdfExtent::{
    length: read_le32(data, offset) & 0x3FFFFFFF,
    location: read_le32(data, offset + 4),
    partition: read_le16(data, offset + 8),
  }
}

///|
/// UDF 目录项。
pub struct UdfEntry {
  name : String
  is_dir : Bool
  size : Int32
}

///|
/// 一个已解析的 UDF 文件/目录（内部表示）。
priv struct UdfNode {
  is_dir : Bool
  size : Int32
  embedded : Bytes
  extents : Array[UdfExtent]
}

///|
/// UDF 映像。
pub struct UdfImage {
  data : Bytes
  block_size : Int32
  partition_start : Int32
  root : UdfExtent
}

///|
/// 解析 UDF 标识符（d-string）：首字节是压缩标识，8 = Latin-1，16 = UTF-16BE。
fn decode_dstring(raw : Bytes) -> String {
  if raw.length() == 0 {
    return ""
  }
  let kind = raw[0].to_uint().reinterpret_as_int()
  let body = sub_bytes(raw, 1, raw.length())
  if kind == 16 {
    decode_ucs2_be(body)
  } else {
    let mut out = ""
    for i = 0; i < body.length(); i = i + 1 {
      out = out +
        Int32::unsafe_to_char(body[i].to_uint().reinterpret_as_int()).to_string()
    }
    out
  }
}

///|
/// 打开 UDF 映像；不是 UDF（没有有效 Anchor）时以 BadDescriptor 失败。
pub fn UdfImage::open(data : Bytes) -> UdfImage raise IsoError {
  let anchor = 256 * 2048
  if anchor + 2048 > data.length() {
    raise Truncated
  }
  let tag = parse_tag(data, anchor)
  if tag.id != 2 || !tag.checksum_ok {
    raise BadDescriptor(tag.id)
  }
  // 主卷描述符序列
  let sequence = read_long_ad(data, anchor + 16)
  if sequence.length <= 0 {
    raise BadDescriptor(0)
  }
  let mut partition_start = -1
  let mut block_size = 2048
  let mut file_set : UdfExtent? = None
  let blocks = sequence.length / 2048
  for i = 0; i < blocks; i = i + 1 {
    let offset = (sequence.location + i) * 2048
    if offset + 2048 > data.length() {
      break
    }
    let t = parse_tag(data, offset)
    if t.id == 5 {
      partition_start = read_le32(data, offset + 188)
    } else if t.id == 6 {
      block_size = read_le32(data, offset + 212)
      file_set = Some(read_long_ad(data, offset + 248))
      // 这些布局改变了文件条目的寻址方式，必须显式拒绝而不是按普通分区读
      for kind in partition_map_kinds(sub_bytes(data, offset, offset + 512)) {
        if kind == "metadata" {
          raise UnsupportedLayout("udf-metadata-partition")
        }
        if kind == "virtual" {
          raise UnsupportedLayout("udf-virtual-partition")
        }
        if kind == "sparable" {
          raise UnsupportedLayout("udf-sparable-partition")
        }
      }
    } else if t.id == 8 {
      break
    }
  }
  if partition_start < 0 {
    raise BadDescriptor(partition_start)
  }
  let fsd = match file_set {
    Some(extent) => extent
    None => raise BadDescriptor(0)
  }
  let fsd_offset = (partition_start + fsd.location) * block_size
  if fsd_offset + 512 > data.length() {
    raise Truncated
  }
  if parse_tag(data, fsd_offset).id != 256 {
    raise BadDescriptor(256)
  }
  let root = read_long_ad(data, fsd_offset + 400)
  UdfImage::{ data, block_size, partition_start, root, }
}

///|
pub fn UdfImage::block_size(self : UdfImage) -> Int32 {
  self.block_size
}

///|
/// 读取 File Entry（ICB），得到文件类型、长度与分配位置。
fn UdfImage::read_entry(
  self : UdfImage,
  icb : UdfExtent,
) -> UdfNode raise IsoError {
  let offset = (self.partition_start + icb.location) * self.block_size
  if offset + 176 > self.data.length() {
    raise Truncated
  }
  let tag = parse_tag(self.data, offset)
  if tag.id == 266 {
    // 扩展文件条目（UDF 2.00+）字段更多，本库按 1.02 的 File Entry 处理，遇到就停
    raise UnsupportedLayout("udf-extended-file-entry")
  }
  if tag.id != 261 {
    raise BadDescriptor(tag.id)
  }
  let file_type = self.data[offset + 27].to_uint().reinterpret_as_int()
  let info_length = read_length64(self.data, offset + 56)
  let l_ea = read_le32(self.data, offset + 168)
  let l_ad = read_le32(self.data, offset + 172)
  let flags = read_le16(self.data, offset + 34)
  let long_ad = (flags & 1) != 0
  let mut embedded = Bytes::new(0)
  let extents : Array[UdfExtent] = []
  let mut at = offset + 176 + l_ea
  let end = at + l_ad
  let step = if long_ad { 16 } else { 8 }
  while at + step <= end {
    let word = read_le32(self.data, at)
    let kind = (word >> 30) & 3
    let length = word & 0x3FFFFFFF
    if kind == 3 {
      // 内嵌数据：目录通常直接放在 File Entry 里
      embedded = sub_bytes(self.data, at + step, at + step + length)
    } else if kind == 0 && length > 0 {
      let location = read_le32(self.data, at + 4)
      let partition = if long_ad {
        read_le16(self.data, at + 8)
      } else {
        icb.partition
      }
      extents.push(UdfExtent::{ length, location, partition, })
    }
    at = at + step
  }
  UdfNode::{ is_dir: file_type == 4, size: info_length, embedded, extents, }
}

///|
/// 取节点内容（内嵌优先，否则按分配描述符拼接）。
fn UdfImage::node_data(self : UdfImage, node : UdfNode) -> Bytes raise IsoError {
  if node.embedded.length() > 0 {
    return node.embedded
  }
  let mut total = 0
  for extent in node.extents {
    total = total + extent.length
  }
  let out = FixedArray::make(total, b'\x00')
  let mut written = 0
  for extent in node.extents {
    let start = (self.partition_start + extent.location) * self.block_size
    if start < 0 || start + extent.length > self.data.length() {
      raise Truncated
    }
    for i = 0; i < extent.length; i = i + 1 {
      out[written + i] = self.data[start + i]
    }
    written = written + extent.length
  }
  Bytes::from_array(out[:])
}

///|
/// 解析目录数据里的 FID 列表，返回 (名字, ICB)。
fn parse_fids(data : Bytes) -> Array[(String, UdfExtent, Bool, Int32)] {
  let out : Array[(String, UdfExtent, Bool, Int32)] = []
  let mut at = 0
  while at + 38 <= data.length() {
    let tag = parse_tag(data, at)
    if tag.id != 257 {
      // 不是 FID：多半已经走到填充区
      break
    }
    let characteristics = data[at + 18].to_uint().reinterpret_as_int()
    let l_fi = data[at + 19].to_uint().reinterpret_as_int()
    let icb = read_long_ad(data, at + 20)
    let l_iu = read_le16(data, at + 36)
    let name_start = at + 38 + l_iu
    let name = if l_fi > 0 {
      decode_dstring(sub_bytes(data, name_start, name_start + l_fi))
    } else {
      ""
    }
    let is_dir = (characteristics & 2) != 0
    let is_parent = (characteristics & 8) != 0
    // FID 总长度按 4 字节对齐
    let step = (38 + l_iu + l_fi + 3) / 4 * 4
    if !is_parent {
      out.push((name, icb, is_dir, step))
    }
    at = at + step
  }
  out
}

///|
/// 列出一级目录。
pub fn UdfImage::list_dir(
  self : UdfImage,
  path : String,
) -> Array[UdfEntry] raise IsoError {
  let segments : Array[String] = []
  for segment in path.split("/") {
    let seg = segment.to_owned()
    if seg != "" {
      segments.push(seg)
    }
  }
  let mut node = self.read_entry(self.root)
  for seg in segments {
    if !node.is_dir {
      raise NotDirectory(path)
    }
    let entries = self.read_dir_entries(node)
    let mut found = false
    for entry in entries {
      if entry.0 == seg {
        node = self.read_entry(entry.1)
        found = true
        break
      }
    }
    if !found {
      raise NotFound(path)
    }
  }
  if !node.is_dir {
    raise NotDirectory(path)
  }
  let out : Array[UdfEntry] = []
  for entry in self.read_dir_entries(node) {
    let (name, icb, is_dir, _) = entry
    let child = self.read_entry(icb)
    out.push(UdfEntry::{ name, is_dir, size: child.size, })
  }
  out
}

///|
fn UdfImage::read_dir_entries(
  self : UdfImage,
  node : UdfNode,
) -> Array[(String, UdfExtent, Bool, Int32)] raise IsoError {
  let data = self.node_data(node)
  parse_fids(data)
}

///|
/// 读取文件内容。
pub fn UdfImage::read_file(
  self : UdfImage,
  path : String,
) -> Bytes raise IsoError {
  let segments : Array[String] = []
  for segment in path.split("/") {
    let seg = segment.to_owned()
    if seg != "" {
      segments.push(seg)
    }
  }
  let mut node = self.read_entry(self.root)
  for seg in segments {
    let entries = self.read_dir_entries(node)
    let mut found = false
    for entry in entries {
      if entry.0 == seg {
        node = self.read_entry(entry.1)
        found = true
        break
      }
    }
    if !found {
      raise NotFound(path)
    }
  }
  if node.is_dir {
    raise IsDirectory(path)
  }
  self.node_data(node)
}
