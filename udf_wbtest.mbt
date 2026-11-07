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
