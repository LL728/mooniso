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
  /// 分块数据源：偏移与长度全程 64 位，映像不必进内存。
  source : ImageSource
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
  UdfImage::open_with_source(ImageSource::from_bytes(data))
}

///|
/// 用分块数据源打开 UDF 映像。
/// 解析全程只按 2048 字节块向宿主取数据：定位 anchor、卷描述符序列、File Set、根 ICB 各读一两块，
/// 因此一张 6 GiB 映像的解析内存占用与 6 KiB 映像相同，**不要求整张映像进内存**。
pub fn UdfImage::open_with_source(
  source : ImageSource,
) -> UdfImage raise IsoError {
  let anchor = read_image_block(source, 256L, 2048)
  let tag = parse_tag(anchor, 0)
  if tag.id != 2 || !tag.checksum_ok {
    raise BadDescriptor(tag.id)
  }
  let sequence = read_long_ad(anchor, 16)
  if sequence.length <= 0 {
    raise BadDescriptor(0)
  }
  let mut partition_start = -1
  let mut block_size = 2048
  let mut file_set : UdfExtent? = None
  let blocks = sequence.length / 2048
  let mut i = 0
  while i < blocks {
    let buf = read_image_block(
      source,
      sequence.location.to_int64() + i.to_int64(),
      2048,
    )
    let t = parse_tag(buf, 0)
    if t.id == 5 {
      partition_start = read_le32(buf, 188)
    } else if t.id == 6 {
      block_size = read_le32(buf, 212)
      file_set = Some(read_long_ad(buf, 248))
      // 这些布局改变了文件条目的寻址方式，必须显式拒绝而不是按普通分区读
      for kind in partition_map_kinds(buf) {
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
    i = i + 1
  }
  if partition_start < 0 {
    raise BadDescriptor(partition_start)
  }
  // UDF 卷的逻辑块固定 2048；其它值说明不是 UDF 1.02 的布局，拒绝而不是按错位读
  if block_size != 2048 {
    raise UnsupportedLayout("udf-block-size")
  }
  let fsd = match file_set {
    Some(extent) => extent
    None => raise BadDescriptor(0)
  }
  let fsd_buf = read_image_block(
    source,
    partition_start.to_int64() + fsd.location.to_int64(),
    block_size,
  )
  if parse_tag(fsd_buf, 0).id != 256 {
    raise BadDescriptor(256)
  }
  let root = read_long_ad(fsd_buf, 400)
  UdfImage::{ source, block_size, partition_start, root, }
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
  let block = self.partition_start.to_int64() + icb.location.to_int64()
  let first = read_image_block(self.source, block, self.block_size)
  let tag = parse_tag(first, 0)
  if tag.id == 259 {
    // 间接条目（ECMA-167 4/14.7）：ICBTag 之后是 16 字节间接 ICB
    let indirect = read_long_ad(first, 36)
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
  let file_type = first[27].to_uint().reinterpret_as_int()
  let info_length = read_length64(first, 56)
  let l_ea = read_le32(first, 168)
  let l_ad = read_le32(first, 172)
  if l_ea < 0 || l_ad < 0 || l_ea > 2147483000 || l_ad > 2147483000 {
    raise Truncated
  }
  let flags = read_le16(first, 34)
  let long_ad = (flags & 1) != 0
  let step = if long_ad { 16 } else { 8 }
  let needed = 176 + l_ea + l_ad
  // 分配描述符跨出首块时按需再取，仍只取这一段，不取整张映像
  let buffer = if needed > first.length() {
    self.source.read_at(block * self.block_size.to_int64(), needed)
  } else {
    first
  }
  let extents : Array[UdfExtent] = []
  self.collect_extents(
    buffer,
    176 + l_ea,
    176 + l_ea + l_ad,
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
  buffer : Bytes,
  start : Int32,
  end : Int32,
  step : Int32,
  default_partition : Int32,
  long_ad : Bool,
  out : Array[UdfExtent],
) -> Unit raise IsoError {
  self.collect_extents_at(
    buffer, start, end, step, default_partition, long_ad, out, 0,
  )
}

///|
/// 递归主体：depth 上限防止自引用 / 长链导致的无限递归（ECMA-167 未限制链长，实现必须自己设界）。
fn UdfImage::collect_extents_at(
  self : UdfImage,
  buffer : Bytes,
  start : Int32,
  end : Int32,
  step : Int32,
  default_partition : Int32,
  long_ad : Bool,
  out : Array[UdfExtent],
  depth : Int32,
) -> Unit raise IsoError {
  if depth > 8 {
    raise BadDescriptor(258)
  }
  let limit = if end > buffer.length() { buffer.length() } else { end }
  let mut at = start
  while at + step <= limit {
    let word = read_le32(buffer, at)
    let kind = (word >> 30) & 3
    let length = word & 0x3FFFFFFF
    let location = read_le32(buffer, at + 4)
    let partition = if long_ad {
      read_le16(buffer, at + 8)
    } else {
      default_partition
    }
    if kind == 0 && length > 0 {
      out.push(UdfExtent::{ length, location, partition, })
    } else if kind == 3 && length > 0 {
      // 下一段分配描述符：位置指向分配扩展描述符（tag 258），按块取回后继续
      let aed_block = self.partition_start.to_int64() + location.to_int64()
      let head = read_image_block(self.source, aed_block, self.block_size)
      let t = parse_tag(head, 0)
      if t.id != 258 {
        raise BadDescriptor(t.id)
      }
      let ad_len = read_le32(head, 20)
      if ad_len < 0 || ad_len > 2147483000 {
        raise Truncated
      }
      let needed = 24 + ad_len
      let aed = if needed > head.length() {
        self.source.read_at(aed_block * self.block_size.to_int64(), needed)
      } else {
        head
      }
      self.collect_extents_at(
        aed,
        24,
        24 + ad_len,
        step,
        partition,
        long_ad,
        out,
        depth + 1,
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
    let start = (self.partition_start.to_int64() + extent.location.to_int64()) *
      self.block_size.to_int64()
    let chunk = self.source.read_at(start, extent.length)
    for i = 0; i < extent.length; i = i + 1 {
      out[written + i] = chunk[i]
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
      // 只向宿主取请求的那一段字节，映像与文件都不整块进内存
      let extent_start = (
          self.partition_start.to_int64() + extent.location.to_int64()
        ) *
        self.block_size.to_int64()
      let base = (from64 - seg_start).to_int()
      let n = (to64 - from64).to_int()
      let chunk = self.source.read_at(extent_start + base.to_int64(), n)
      for k = 0; k < n; k = k + 1 {
        out[written + k] = chunk[k]
      }
      written = written + n
    }
    seg_start = seg_end
  }
  // 分配描述符必须覆盖请求区间：覆盖不足说明映像结构异常，不能静默补 0 当成数据返回
  if written < want {
    raise Truncated
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

///|
/// 按逻辑块号从数据源取一块或若干块：块号与偏移全程 64 位，越界由 read_at 抛 Truncated。
fn read_image_block(
  source : ImageSource,
  block : Int64,
  block_size : Int32,
) -> Bytes raise IsoError {
  let size = block_size.to_int64()
  if block < 0L || size <= 0L || size > 2147483647L {
    raise Truncated
  }
  source.read_at(block * size, size.to_int())
}
