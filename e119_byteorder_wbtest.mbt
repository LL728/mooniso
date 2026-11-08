// ByteReader 单元测试：三种字节序、越界与 both-endian 不一致。

///|
test "read_u16 both orders" {
  // 同一段字节按不同字节序解释的结果必须不同，交叉验证两种实现
  let data = bytes_of([b'\x00', b'\x08', b'\x08', b'\x00'])
  let r = ByteReader::new(data)
  assert_eq(r.read_u16_le(), 2048)
  let r2 = ByteReader::new(data)
  assert_eq(r2.read_u16_be(), 8)
  let r3 = ByteReader::new(data)
  assert_eq(r3.read_u16_be(), 8)
}

///|
test "read_u32 both-endian accepts matching halves" {
  let data = bytes_of([
    b'\x18', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x18',
  ])
  let r = ByteReader::new(data)
  assert_eq(r.read_u32_both(), 24)
}

///|
test "read_u32 both-endian rejects mismatched halves" {
  let data = bytes_of([
    b'\x01', b'\x00', b'\x00', b'\x00', b'\x02', b'\x00', b'\x00', b'\x00',
  ])
  let r = ByteReader::new(data)
  let failed = try {
    let _ = r.read_u32_both()
    false
  } catch {
    BadBothEndian => true
    _ => false
  }
  assert_true(failed)
}

///|
test "reads past the end fail with Truncated" {
  let r = ByteReader::new(bytes_of([b'\x01']))
  let failed = try {
    let _ = r.read_u32_le()
    false
  } catch {
    Truncated => true
    _ => false
  }
  assert_true(failed)
}

///|
test "read_ascii stops at NUL and trims trailing spaces" {
  let r = ByteReader::new(
    bytes_of([b'M', b'O', b'O', b'N', b'\x00', b' ', b' ', b' ']),
  )
  assert_eq(r.read_ascii(8), "MOON")
}

///|
test "read_bytes preserves content and advances position" {
  let r = ByteReader::new(bytes_of([b'\xAA', b'\xBB', b'\xCC']))
  r.skip(1)
  let got = r.read_bytes(1)
  assert_eq(got[0], b'\xBB')
  assert_eq(r.position(), 2)
  assert_eq(r.remaining(), 1)
}
