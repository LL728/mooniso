// UDF 读取的单元测试：tag 校验和与 d-string 名字解码。

///|
test "tag checksum accepts a well formed descriptor" {
  // 16 字节 tag，id = 2（Anchor），第 4 字节是校验和
  let raw = bytes_of([
    b'\x02', b'\x00', b'\x01', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x01',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
  ])
  let mut sum = 0
  for i = 0; i < 16; i = i + 1 {
    if i != 4 {
      sum = sum + raw[i].to_uint().reinterpret_as_int()
    }
  }
  let fixed = FixedArray::make(16, b'\x00')
  for i = 0; i < 16; i = i + 1 {
    fixed[i] = raw[i]
  }
  fixed[4] = (sum % 256).to_byte()
  let tag = parse_tag(Bytes::from_array(fixed[:]), 0)
  assert_eq(tag.id, 2)
  assert_true(tag.checksum_ok)
}

///|
test "dstring decodes latin-1 and utf-16" {
  let latin = bytes_of([b'\x08', b'h', b'i'])
  assert_eq(decode_dstring(latin), "hi")
  let utf16 = bytes_of([b'\x10', b'\x8B', b'\xF4', b'\x66', b'\x0E'])
  assert_eq(decode_dstring(utf16), "说明")
}

///|
/// 在缓冲区写一个合法的 UDF 描述符 tag（校验和 = 除第 4 字节外 16 字节之和 mod 256）。
fn put_tag(buf : FixedArray[Byte], offset : Int32, id : Int32) -> Unit {
  for i = 0; i < 16; i = i + 1 {
    buf[offset + i] = b'\x00'
  }
  // id 可能超过 255（File Set Descriptor 是 256），两个字节都要写
  buf[offset] = (id & 0xFF).to_byte()
  buf[offset + 1] = ((id >> 8) & 0xFF).to_byte()
  buf[offset + 2] = b'\x01'
  let mut sum = 0
  for i = 0; i < 16; i = i + 1 {
    if i != 4 {
      sum = sum + buf[offset + i].to_uint().reinterpret_as_int()
    }
  }
  buf[offset + 4] = (sum % 256).to_byte()
}

///|
fn put_le32(buf : FixedArray[Byte], offset : Int32, value : Int32) -> Unit {
  buf[offset] = (value & 0xFF).to_byte()
  buf[offset + 1] = ((value >> 8) & 0xFF).to_byte()
  buf[offset + 2] = ((value >> 16) & 0xFF).to_byte()
  buf[offset + 3] = ((value >> 24) & 0xFF).to_byte()
}

///|
fn put_ascii(buf : FixedArray[Byte], offset : Int32, text : String) -> Unit {
  let raw = text.to_array()
  for i = 0; i < raw.length(); i = i + 1 {
    buf[offset + i] = (raw[i].to_int() & 0xFF).to_byte()
  }
}

///|
test "type 2 metadata partition map is classified as metadata" {
  let buf = FixedArray::make(512, b'\x00')
  put_le32(buf, 264, 64)
  put_le32(buf, 268, 1)
  buf[440] = b'\x02'
  buf[441] = b'\x40'
  put_ascii(buf, 443, "*UDF Metadata Partition")
  let kinds = partition_map_kinds(Bytes::from_array(buf[:]))
  assert_eq(kinds.length(), 1)
  assert_eq(kinds[0], "metadata")
}

///|
test "type 1 partition map is classified as type1" {
  let buf = FixedArray::make(512, b'\x00')
  put_le32(buf, 264, 6)
  put_le32(buf, 268, 1)
  buf[440] = b'\x01'
  buf[441] = b'\x06'
  let kinds = partition_map_kinds(Bytes::from_array(buf[:]))
  assert_eq(kinds.length(), 1)
  assert_eq(kinds[0], "type1")
}

///|
test "virtual partition map is not mistaken for a plain partition" {
  let buf = FixedArray::make(512, b'\x00')
  put_le32(buf, 264, 64)
  put_le32(buf, 268, 1)
  buf[440] = b'\x02'
  buf[441] = b'\x40'
  put_ascii(buf, 443, "*UDF Virtual Partition")
  let kinds = partition_map_kinds(Bytes::from_array(buf[:]))
  assert_eq(kinds[0], "virtual")
}

///|
test "image that declares a metadata partition is rejected explicitly" {
  // 4 块：Anchor(256) 指向 300 起的描述符序列；LVD 带元数据分区映射
  let buf = FixedArray::make(2048 * 400, b'\x00')
  // Anchor
  put_tag(buf, 256 * 2048, 2)
  put_le32(buf, 256 * 2048 + 16, 2048 * 3)
  put_le32(buf, 256 * 2048 + 20, 300)
  // 主卷描述符（id 1）
  put_tag(buf, 300 * 2048, 1)
  // 分区描述符（id 5）：分区起点 400
  put_tag(buf, 301 * 2048, 5)
  put_le32(buf, 301 * 2048 + 188, 400)
  // 逻辑卷描述符（id 6）：块大小 2048、File Set 位置、一个 Type 2 元数据映射
  put_tag(buf, 302 * 2048, 6)
  put_le32(buf, 302 * 2048 + 212, 2048)
  put_le32(buf, 302 * 2048 + 248, 10)
  put_le32(buf, 302 * 2048 + 250, 401)
  put_le32(buf, 302 * 2048 + 264, 64)
  put_le32(buf, 302 * 2048 + 268, 1)
  buf[302 * 2048 + 440] = b'\x02'
  buf[302 * 2048 + 441] = b'\x40'
  put_ascii(buf, 302 * 2048 + 443, "*UDF Metadata Partition")
  let reason = try {
    let _ = UdfImage::open(Bytes::from_array(buf[:]))
    "opened"
  } catch {
    UnsupportedLayout(name) => name
    _ => "other-error"
  }
  assert_eq(reason, "udf-metadata-partition")
}

///|
fn put_le16(buf : FixedArray[Byte], offset : Int32, value : Int32) -> Unit {
  buf[offset] = (value & 0xFF).to_byte()
  buf[offset + 1] = ((value >> 8) & 0xFF).to_byte()
}

///|
fn put_le64(buf : FixedArray[Byte], offset : Int32, value : Int64) -> Unit {
  let mut i = 0
  while i < 8 {
    buf[offset + i] = ((value >> (i * 8)) & 0xFFL).to_int().to_byte()
    i = i + 1
  }
}

///|
/// 造一张最小 UDF 映像骨架：Anchor(256) -> VDS(300..302) -> FSD(310) -> 根 FE(320) -> 根目录数据(321)。
/// 根目录里有一个文件 F.BIN，其 ICB 默认指向 330，数据默认在 340。
fn udf_fixture() -> FixedArray[Byte] {
  let buf = FixedArray::make(2048 * 400, (0).to_byte())
  put_tag(buf, 256 * 2048, 2)
  put_le32(buf, 256 * 2048 + 16, 2048 * 3)
  put_le32(buf, 256 * 2048 + 20, 300)
  put_tag(buf, 300 * 2048, 1)
  put_tag(buf, 301 * 2048, 5)
  put_le32(buf, 301 * 2048 + 188, 0)
  put_tag(buf, 302 * 2048, 6)
  put_le32(buf, 302 * 2048 + 212, 2048)
  put_le32(buf, 302 * 2048 + 248, 2048 * 2)
  put_le32(buf, 302 * 2048 + 252, 310)
  put_le32(buf, 302 * 2048 + 268, 0)
  put_tag(buf, 310 * 2048, 256)
  put_le32(buf, 310 * 2048 + 400, 2048)
  put_le32(buf, 310 * 2048 + 404, 320)
  put_tag(buf, 320 * 2048, 261)
  buf[320 * 2048 + 27] = (4).to_byte()
  put_le64(buf, 320 * 2048 + 56, 2048L)
  put_le32(buf, 320 * 2048 + 172, 8)
  put_le32(buf, 320 * 2048 + 176, 2048)
  put_le32(buf, 320 * 2048 + 180, 321)
  // 根目录数据：一条 FID，指向 ICB 330
  let fid = 321 * 2048
  put_tag(buf, fid, 257)
  buf[fid + 18] = (0).to_byte()
  // d-string：首字节是压缩标识（8 = Latin-1），后面才是名字
  buf[fid + 19] = (6).to_byte()
  put_le32(buf, fid + 20, 2048)
  put_le32(buf, fid + 24, 330)
  put_le16(buf, fid + 36, 0)
  buf[fid + 38] = (8).to_byte()
  put_ascii(buf, fid + 39, "F.BIN")
  // 文件 FE：8 字节内容在块 340
  put_tag(buf, 330 * 2048, 261)
  buf[330 * 2048 + 27] = (1).to_byte()
  put_le64(buf, 330 * 2048 + 56, 8L)
  put_le32(buf, 330 * 2048 + 172, 8)
  put_le32(buf, 330 * 2048 + 176, 8)
  put_le32(buf, 330 * 2048 + 180, 340)
  put_ascii(buf, 340 * 2048, "ABCDEFGH")
  buf
}

///|
test "udf reads a small file by size, whole file and range" {
  let image = UdfImage::open(Bytes::from_array(udf_fixture()[:]))
  assert_eq(image.file_size("/F.BIN"), 8L)
  assert_eq(image.read_file("/F.BIN").length(), 8)
  let slice = image.read_range("/F.BIN", 1L, 3)
  assert_eq(slice.length(), 3)
  assert_eq(slice[0], b'B')
  assert_eq(slice[2], b'D')
  assert_eq(image.read_range("/F.BIN", 4L, 0).length(), 4)
}

///|
/// UDF 1.02 的信息长度是 64 位：大于 4 GiB 的文件是合法输入，
/// 读取侧必须原样给出长度，只在「整文件物化」这一步按平台上限拒绝。
test "udf reports a file over 4 GiB with full 64 bit length" {
  let buf = udf_fixture()
  put_le32(buf, 330 * 2048 + 60, 1) // 信息长度高 32 位 = 1 -> 4 GiB
  put_le32(buf, 330 * 2048 + 56, 0)
  let image = UdfImage::open(Bytes::from_array(buf[:]))
  assert_eq(image.file_size("/F.BIN"), 4294967296L)
  let entries = image.list_dir("/")
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].size, 4294967296L)
  let too_large = try {
    let _ = image.read_file("/F.BIN")
    false
  } catch {
    PayloadTooLarge(n) => n == 4294967296L
    _ => false
  }
  assert_true(too_large)
  // 分块读取不因声明长度超 4 GiB 而失败
  assert_eq(image.read_range("/F.BIN", 0L, 8).length(), 8)
}

///|
/// 间接条目（tag 259，ECMA-167 4/14.7）：ICBTag 之后的 16 字节指向真正的 ICB。
test "udf follows an indirect entry" {
  let buf = udf_fixture()
  let fid = 321 * 2048
  put_le32(buf, fid + 24, 332)
  put_tag(buf, 332 * 2048, 259)
  put_le32(buf, 332 * 2048 + 36, 2048)
  put_le32(buf, 332 * 2048 + 40, 330)
  let image = UdfImage::open(Bytes::from_array(buf[:]))
  assert_eq(image.file_size("/F.BIN"), 8L)
  assert_eq(image.read_file("/F.BIN").length(), 8)
}

///|
/// 分配描述符的 extent type 3 是「下一段分配描述符」，指向分配扩展描述符（tag 258）。
test "udf follows an allocation extent continuation" {
  let buf = udf_fixture()
  // FE 的 short_ad 改成 type 3，指向块 333
  put_le32(buf, 330 * 2048 + 176, (3 << 30) | 8)
  put_le32(buf, 330 * 2048 + 180, 333)
  // 分配扩展描述符：8 字节 AD，指向块 340
  put_tag(buf, 333 * 2048, 258)
  put_le32(buf, 333 * 2048 + 20, 8)
  put_le32(buf, 333 * 2048 + 24, 8)
  put_le32(buf, 333 * 2048 + 28, 340)
  let image = UdfImage::open(Bytes::from_array(buf[:]))
  let data = image.read_file("/F.BIN")
  assert_eq(data.length(), 8)
  assert_eq(data[0], b'A')
  assert_eq(data[7], b'H')
}

///|
test "udf treats a terminal entry as an empty file" {
  let buf = udf_fixture()
  let fid = 321 * 2048
  put_le32(buf, fid + 24, 334)
  put_tag(buf, 334 * 2048, 260)
  let image = UdfImage::open(Bytes::from_array(buf[:]))
  assert_eq(image.file_size("/F.BIN"), 0L)
}

///|
/// 分配描述符延续若指回自身，必须报错而不是无限递归。
test "udf rejects a self-referencing allocation extent chain" {
  let buf = udf_fixture()
  put_le32(buf, 330 * 2048 + 176, (3 << 30) | 8)
  put_le32(buf, 330 * 2048 + 180, 333)
  put_tag(buf, 333 * 2048, 258)
  put_le32(buf, 333 * 2048 + 20, 8)
  // 延续描述符又指回 333 自己
  put_le32(buf, 333 * 2048 + 24, (3 << 30) | 8)
  put_le32(buf, 333 * 2048 + 28, 333)
  let image = UdfImage::open(Bytes::from_array(buf[:]))
  let failed = try {
    let _ = image.read_file("/F.BIN")
    false
  } catch {
    BadDescriptor(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
/// 声明长度大于分配描述符覆盖范围时，不能静默补 0 当作数据。
test "udf read_range rejects a range the extents do not cover" {
  let buf = udf_fixture()
  put_le64(buf, 330 * 2048 + 56, 16L) // 声明 16 字节，但只分配了 8 字节
  let image = UdfImage::open(Bytes::from_array(buf[:]))
  assert_eq(image.file_size("/F.BIN"), 16L)
  let failed = try {
    let _ = image.read_range("/F.BIN", 0L, 16)
    false
  } catch {
    Truncated => true
    _ => false
  }
  assert_true(failed)
}

///|
/// UDF 逻辑块固定 2048：声明其它块大小的映像不是 1.02 布局，必须显式拒绝。
test "udf rejects a volume that declares a non 2048 block size" {
  let buf = udf_fixture()
  put_le32(buf, 302 * 2048 + 212, 4096)
  let reason = try {
    let _ = UdfImage::open(Bytes::from_array(buf[:]))
    "opened"
  } catch {
    UnsupportedLayout(name) => name
    _ => "other"
  }
  assert_eq(reason, "udf-block-size")
}
