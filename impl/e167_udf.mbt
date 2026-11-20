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
/// UDF 的信息长度是 64 位（ECMA-167 4/14.9）。按原样返回 Int64：
/// UDF 1.02 允许单文件超过 4 GiB（由 64 位长度表示），读取侧不得因长度高位非零而拒绝；
/// 是否物化成单个 Bytes 由调用方按平台上限决定（Bytes 索引是 32 位）。
fn read_length64(data : Bytes, offset : Int32) -> Int64 {
  let hi = read_le32(data, offset + 4).to_int64() & 0xFFFFFFFFL
  let lo = read_le32(data, offset).to_int64() & 0xFFFFFFFFL
  (hi << 32) | lo
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
  /// 64 位信息长度：UDF 1.02 允许单文件超过 4 GiB
  size : Int64
}

///|
/// 一个已解析的 UDF 文件/目录（内部表示）。
priv struct UdfNode {
  is_dir : Bool
  size : Int64
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
    let offset = block_offset(sequence.location + i, 2048, data.length()) catch {
      _ => break
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
  let fsd_offset = extent_offset(
    partition_start + fsd.location,
    512,
    block_size,
    data.length(),
  )
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

///|
/// 解析 ICB 链并收集分配描述符。
/// 支持 UDF 1.02 的三种 ICB 形式：文件条目（tag 261）、间接条目（tag 259）、终止条目（tag 260）；
/// 分配描述符的 extent type 3 按 ECMA-167 4/14.4 解释为「下一段分配描述符」，
/// 指向分配扩展描述符（tag 258）后继续收集。
fn UdfImage::read_entry(
  self : UdfImage,
  icb : UdfExtent,
) -> UdfNode raise IsoError {
  let offset = extent_offset(
    self.partition_start + icb.location,
    176,
    self.block_size,
    self.data.length(),
  )
  let tag = parse_tag(self.data, offset)
  if tag.id == 259 {
    // 间接条目（ECMA-167 4/14.7）：ICBTag 之后是 16 字节间接 ICB
    let indirect = read_long_ad(self.data, offset + 36)
    return self.read_entry(indirect)
  }
  if tag.id == 260 {
    // 终止条目：空节点
    return UdfNode::{ is_dir: false, size: 0L, extents: [], }
  }
  if tag.id == 266 {
    // 扩展文件条目属 UDF 2.00+，不在 1.02 范围内
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
  let step = if long_ad { 16 } else { 8 }
  let extents : Array[UdfExtent] = []
  self.collect_extents(
    offset + 176 + l_ea,
    offset + 176 + l_ea + l_ad,
    step,
    icb.partition,
    long_ad,
    extents,
  )
  UdfNode::{ is_dir: file_type == 4, size: info_length, extents, }
}

///|
/// 收集分配描述符区间 [start, end) 内的 extent；extent type 3 递归到分配扩展描述符。
fn UdfImage::collect_extents(
  self : UdfImage,
  start : Int32,
  end : Int32,
  step : Int32,
  default_partition : Int32,
  long_ad : Bool,
  out : Array[UdfExtent],
) -> Unit raise IsoError {
  let mut at = start
  while at + step <= end {
    let word = read_le32(self.data, at)
    let kind = (word >> 30) & 3
    let length = word & 0x3FFFFFFF
    let location = read_le32(self.data, at + 4)
    let partition = if long_ad {
      read_le16(self.data, at + 8)
    } else {
      default_partition
    }
    if kind == 0 && length > 0 {
      out.push(UdfExtent::{ length, location, partition, })
    } else if kind == 3 && length > 0 {
      // 下一段分配描述符：位置指向分配扩展描述符（tag 258）
      let aed = extent_offset(
        self.partition_start + location,
        24,
        self.block_size,
        self.data.length(),
      )
      let t = parse_tag(self.data, aed)
      if t.id != 258 {
        raise BadDescriptor(t.id)
      }
      let ad_len = read_le32(self.data, aed + 20)
      self.collect_extents(
        aed + 24,
        aed + 24 + ad_len,
        step,
        partition,
        long_ad,
        out,
      )
    }
    at = at + step
  }
}

///|
/// 取节点内容（内嵌优先，否则按分配描述符拼接）。

///|
/// 把节点内容拼成单个 Bytes（目录数据用）。超过 Bytes 上限时拒绝而不是截断。
fn UdfImage::node_data(self : UdfImage, node : UdfNode) -> Bytes raise IsoError {
  let mut total : Int64 = 0L
  for extent in node.extents {
    total = total + extent.length.to_int64()
  }
  if total > 2147483647L {
    raise PayloadTooLarge(total)
  }
  let n = total.to_int()
  let out = FixedArray::make(n, (0).to_byte())
  let mut written = 0
  for extent in node.extents {
    let start = extent_offset(
      self.partition_start + extent.location,
      extent.length,
      self.block_size,
      self.data.length(),
    )
    for i = 0; i < extent.length; i = i + 1 {
      if written + i < n {
        out[written + i] = self.data[start + i]
      }
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

///|
/// 按路径解析到节点（目录或文件）。
fn UdfImage::resolve_node(
  self : UdfImage,
  path : String,
) -> UdfNode raise IsoError {
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
  node
}

///|
/// 文件大小（64 位，原样给出 UDF 的信息长度；不受 Bytes 上限影响）。
pub fn UdfImage::file_size(
  self : UdfImage,
  path : String,
) -> Int64 raise IsoError {
  let node = self.resolve_node(path)
  node.size
}

///|
/// 读取文件的一段：offset 与 length 都用 64 位规划，length 为 0 时读到文件末尾。
/// 这是合法大文件（含 > 4 GiB）的读取路径：绕开「整文件物化成一个 Bytes」的 32 位上限。
pub fn UdfImage::read_range(
  self : UdfImage,
  path : String,
  offset : Int64,
  length : Int32,
) -> Bytes raise IsoError {
  let node = self.resolve_node(path)
  if node.is_dir {
    raise IsDirectory(path)
  }
  if offset < 0L || length < 0 {
    raise Truncated
  }
  let total = node.size
  if offset > total {
    raise Truncated
  }
  let want64 = if length == 0 { total - offset } else { length.to_int64() }
  if offset + want64 > total || want64 > 2147483647L {
    raise Truncated
  }
  let want = want64.to_int()
  let out = FixedArray::make(want, (0).to_byte())
  let mut written = 0
  let mut seg_start : Int64 = 0L
  for extent in node.extents {
    if written >= want {
      break
    }
    let seg_end = seg_start + extent.length.to_int64()
    if offset < seg_end && offset + want64 > seg_start {
      let from64 = if offset > seg_start { offset } else { seg_start }
      let to64 = if offset + want64 < seg_end {
        offset + want64
      } else {
        seg_end
      }
      let start = extent_offset(
        self.partition_start + extent.location,
        extent.length,
        self.block_size,
        self.data.length(),
      )
      let base = (from64 - seg_start).to_int()
      let n = (to64 - from64).to_int()
      for k = 0; k < n; k = k + 1 {
        out[written + k] = self.data[start + base + k]
      }
      written = written + n
    }
    seg_start = seg_end
  }
  Bytes::from_array(out[:])
}

///|
/// 读取整个文件（物化为单个 Bytes）。
/// UDF 1.02 允许大于 4 GiB 的文件，而 Bytes 的索引是 32 位：
/// 超过 2 GiB−1 时抛 PayloadTooLarge，请改用 read_range 分块读取。
pub fn UdfImage::read_file(
  self : UdfImage,
  path : String,
) -> Bytes raise IsoError {
  let node = self.resolve_node(path)
  if node.is_dir {
    raise IsDirectory(path)
  }
  if node.size > 2147483647L {
    raise PayloadTooLarge(node.size)
  }
  self.node_data(node)
}
