// 目录记录单元测试。

///|
/// 构造一条目录记录的字节序列（不含 system use area），extra 会 OR 进 flags。
fn make_record_flags(
  name : Array[Byte],
  is_dir : Bool,
  extent : Int32,
  size : Int32,
  extra : Int32,
) -> Array[Byte] {
  let out : Array[Byte] = []
  let flags : Byte = ((if is_dir { 2 } else { 0 }) | extra).to_byte()
  // 记录长度先占位
  out.push(b'\x00')
  out.push(b'\x00')
  // extent / size 的 both-endian 形式
  for value in [extent, size] {
    out.push((value & 0xFF).to_byte())
    out.push(((value >> 8) & 0xFF).to_byte())
    out.push(((value >> 16) & 0xFF).to_byte())
    out.push(((value >> 24) & 0xFF).to_byte())
    out.push(((value >> 24) & 0xFF).to_byte())
    out.push(((value >> 16) & 0xFF).to_byte())
    out.push(((value >> 8) & 0xFF).to_byte())
    out.push((value & 0xFF).to_byte())
  }
  for b in [b'\x7E', b'\x01', b'\x02', b'\x03', b'\x04', b'\x05', b'\x00'] {
    out.push(b)
  }
  out.push(flags)
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x01') // 卷序号：小端 01 00，大端 00 01
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x01')
  out.push(name.length().to_byte())
  for b in name {
    out.push(b)
  }
  if name.length() % 2 == 0 {
    out.push(b'\x00')
  }
  out[0] = out.length().to_byte()
  out
}

///|
fn make_record(
  name : Array[Byte],
  is_dir : Bool,
  extent : Int32,
  size : Int32,
) -> Array[Byte] {
  make_record_flags(name, is_dir, extent, size, 0)
}

///|
test "normalize strips version and dangling dot" {
  assert_eq(normalize_iso_name("HELLO.TXT;1"), "HELLO.TXT")
  assert_eq(normalize_iso_name("README.;1"), "README")
  assert_eq(normalize_iso_name("SUB"), "SUB")
}

///|
test "parses a file record" {
  let rec = make_record(
    [b'H', b'E', b'L', b'L', b'O', b'.', b'T', b'X', b'T', b';', b'1'],
    false,
    22,
    17,
  )
  let r = ByteReader::new(bytes_of(rec))
  let (record, len) = parse_directory_record(r)
  assert_eq(record.name, "HELLO.TXT")
  assert_eq(record.extent, 22)
  assert_eq(record.size, 17)
  assert_eq(record.is_dir(), false)
  assert_eq(len, rec.length())
  assert_eq(record.date.year, 2026)
  assert_eq(record.date.month, 1)
}

///|
test "parses a directory record" {
  let rec = make_record([b'S', b'U', b'B'], true, 21, 2048)
  let (record, _) = parse_directory_record(ByteReader::new(bytes_of(rec)))
  assert_eq(record.name, "SUB")
  assert_true(record.is_dir())
}

///|
test "zero length record means sector padding" {
  let data = bytes_of([b'\x00', b'\x00', b'\x00'])
  let (record, len) = parse_directory_record(ByteReader::new(data))
  assert_eq(len, 0)
  assert_eq(record.name, "")
}

///|
test "special names for self and parent" {
  let self_rec = make_record([b'\x00'], true, 20, 2048)
  let (record, _) = parse_directory_record(ByteReader::new(bytes_of(self_rec)))
  assert_true(record.is_special())
}

///|
test "too short record is rejected" {
  let data = bytes_of([b'\x05', b'\x00', b'\x00'])
  let failed = try {
    let _ = parse_directory_record(ByteReader::new(data))
    false
  } catch {
    BadDirectoryRecord(len) => len == 5
    _ => false
  }
  assert_true(failed)
}
