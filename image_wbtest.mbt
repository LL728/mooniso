// IsoImage 单元测试：用合成映像覆盖多段文件合并与内容拼接。

///|
fn date_fixture() -> RecordDate {
  RecordDate::{
    year: 2026,
    month: 1,
    day: 2,
    hour: 3,
    minute: 4,
    second: 5,
    gmt_offset_quarters: 0,
  }
}

///|
/// 合成映像：4 个逻辑块。
///   block 1 = 根目录数据（. / .. / BIG.BIN 两段 / TAIL.TXT）
///   block 2 = 3 字节（BIG.BIN 第一段 + TAIL.TXT 的第一字节）
///   block 3 = 2 字节（BIG.BIN 第二段）
fn synthetic_image() -> IsoImage {
  let data = FixedArray::make(4 * 2048, b'\x00')
  let records : Array[Byte] = []
  for rec in make_record_flags([b'\x00'], true, 1, 2048, 0) {
    records.push(rec)
  }
  for rec in make_record_flags([b'\x01'], true, 1, 2048, 0) {
    records.push(rec)
  }
  let big = [b'B', b'I', b'G', b'.', b'B', b'I', b'N', b';', b'1']
  for rec in make_record_flags(big, false, 2, 3, 0x80) {
    records.push(rec)
  }
  for rec in make_record_flags(big, false, 3, 2, 0) {
    records.push(rec)
  }
  let tail = [b'T', b'A', b'I', b'L', b'.', b'T', b'X', b'T', b';', b'1']
  for rec in make_record_flags(tail, false, 2, 1, 0) {
    records.push(rec)
  }
  for i = 0; i < records.length(); i = i + 1 {
    data[2048 + i] = records[i]
  }
  data[2 * 2048 + 0] = b'\x01'
  data[2 * 2048 + 1] = b'\x02'
  data[2 * 2048 + 2] = b'\x03'
  data[3 * 2048 + 0] = b'\x04'
  data[3 * 2048 + 1] = b'\x05'
  IsoImage::{
    data: Bytes::from_array(data[:]),
    volume_id: "SYNTH",
    block_size: 2048,
    volume_space_size: 4,
    root: DirectoryRecord::{
      extent: 1,
      size: 2048,
      flags: 2,
      name: "",
      date: date_fixture(),
    },
  }
}

///|
test "list_dir merges multi-extent records into one entry" {
  let image = synthetic_image()
  let entries = image.list_dir("/")
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].name, "BIG.BIN")
  assert_eq(entries[0].size, 5)
  assert_eq(entries[0].is_multi_extent(), false)
  assert_eq(entries[1].name, "TAIL.TXT")
  assert_eq(entries[1].size, 1)
}

///|
test "read_file concatenates extents in order" {
  let bytes = synthetic_image().read_file("/big.bin")
  assert_eq(bytes.length(), 5)
  assert_eq(bytes[0], b'\x01')
  assert_eq(bytes[2], b'\x03')
  assert_eq(bytes[3], b'\x04')
  assert_eq(bytes[4], b'\x05')
}

///|
test "read_file on a directory fails with IsDirectory" {
  let failed = try {
    let _ = synthetic_image().read_file("/")
    false
  } catch {
    IsDirectory(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "find_record reports missing paths" {
  let failed = try {
    let _ = synthetic_image().find_record("/nope")
    false
  } catch {
    NotFound(_) => true
    _ => false
  }
  assert_true(failed)
}
