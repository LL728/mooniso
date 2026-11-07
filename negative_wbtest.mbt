// 负例测试：把一张好映像改坏，确认错误被明确识别（而不是静默读出错数据）。

///|
/// 生成一张最小好映像。
fn good_image() -> Bytes raise IsoError {
  let builder = IsoBuilder::new()
  builder.volume_id("NEGATIVE")
  builder.add_file("/hello.txt", bytes_of([b'h', b'i']))
  builder.add_directory("/Docs")
  builder.add_file("/Docs/note.txt", bytes_of([b'n']))
  builder.build()
}

///|
fn mutate(data : Bytes, offset : Int32, value : Byte) -> Bytes {
  let out = FixedArray::make(data.length(), b'\x00')
  for i = 0; i < data.length(); i = i + 1 {
    out[i] = data[i]
  }
  out[offset] = value
  Bytes::from_array(out[:])
}

///|
test "truncated image is rejected" {
  let full = good_image()
  let cut = sub_bytes(full, 0, 16 * 2048)
  let failed = try {
    let _ = IsoImage::open(cut)
    false
  } catch {
    Truncated => true
    _ => false
  }
  assert_true(failed)
}

///|
test "wrong signature is rejected" {
  let full = good_image()
  // PVD 的 "CD001" 魔数在扇区 16 的偏移 1..5
  let broken = mutate(full, 16 * 2048 + 1, b'X')
  let failed = try {
    let _ = IsoImage::open(broken)
    false
  } catch {
    BadSignature => true
    _ => false
  }
  assert_true(failed)
}

///|
test "inconsistent both-endian volume size is rejected" {
  let full = good_image()
  // 卷空间大小的 both-endian 字段：偏移 80 起 8 字节，改大端那半
  let broken = mutate(full, 16 * 2048 + 84, b'\x7F')
  let failed = try {
    let _ = IsoImage::open(broken)
    false
  } catch {
    BadBothEndian => true
    _ => false
  }
  assert_true(failed)
}

///|
test "directory record with impossible length is rejected" {
  let full = good_image()
  let image = IsoImage::open(full)
  // 根目录数据块的第一个字节就是 "." 记录的长度；改成 5 触发非法长度
  let broken = mutate(full, image.root().extent * 2048, b'\x05')
  let failed = try {
    let _ = IsoImage::open(broken).list_dir("/")
    false
  } catch {
    BadDirectoryRecord(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "reading past a truncated image is rejected" {
  let full = good_image()
  let image = IsoImage::open(full)
  let entry = image.find_record("/hello.txt")
  // 把映像截断到文件内容所在扇区之前，读取时必须报 Truncated
  let cut = sub_bytes(full, 0, entry.extent * 2048)
  let failed = try {
    let _ = IsoImage::open(cut).read_file("/hello.txt")
    false
  } catch {
    Truncated => true
    _ => false
  }
  assert_true(failed)
}
