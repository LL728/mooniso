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
  buf[offset] = id.to_byte()
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
