// Joliet（UCS-2 大端）名字解码的单元测试。

///|
test "decode_ucs2_be reads BMP characters" {
  // "Hi 你好"
  let raw = bytes_of([
    b'\x00', b'H', b'\x00', b'i', b'\x00', b' ', b'\x4F', b'\x60', b'\x59', b'\x7D',
  ])
  assert_eq(decode_ucs2_be(raw), "Hi 你好")
}

///|
test "decode_ucs2_be stops at NUL" {
  let raw = bytes_of([b'\x00', b'A', b'\x00', b'\x00', b'\x00', b'B'])
  assert_eq(decode_ucs2_be(raw), "A")
}

///|
test "decode_ucs2_be joins surrogate pairs" {
  // U+1F600 = D83D DE00
  let raw = bytes_of([b'\xD8', b'\x3D', b'\xDE', b'\x00'])
  assert_eq(decode_ucs2_be(raw), "\u{1F600}")
}

///|
test "joliet directory record decodes UCS-2 name" {
  // name_len = 10 字节 = 5 个 UCS-2 字符："Test1"
  let name = [
    b'\x00', b'T', b'\x00', b'e', b'\x00', b's', b'\x00', b't', b'\x00', b'1',
  ]
  let rec = make_record_flags(name, false, 40, 100, 0)
  let (record, _) = parse_directory_record_in(
    ByteReader::new(bytes_of(rec)),
    true,
  )
  assert_eq(record.name, "Test1")
  assert_eq(record.extent, 40)
  assert_eq(record.size, 100)
}

///|
test "rock ridge aware parser keeps ISO name when not joliet" {
  let name = [b'A', b'.', b'T', b'X', b'T', b';', b'1']
  let rec = make_record_flags(name, false, 41, 7, 0)
  let (record, _) = parse_directory_record_in(
    ByteReader::new(bytes_of(rec)),
    false,
  )
  assert_eq(record.name, "A.TXT")
}

///|
test "decode ucs2 handles the CJK bytes our writer emits" {
  let raw = bytes_of([
    b'\x8B', b'\xF4', b'\x66', b'\x0E', b'\x00', b'.', b'\x00', b't', b'\x00', b'x',
    b'\x00', b't', b'\x00', b';', b'\x00', b'1',
  ])
  assert_eq(decode_ucs2_be(raw), "说明.txt;1")
  assert_eq(normalize_iso_name(decode_ucs2_be(raw)), "说明.txt")
}
