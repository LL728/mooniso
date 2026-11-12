// 健壮性判据：畸形映像必须报错，不能读错数据、不能先分配巨型缓冲、不能无限递归。

///|
fn robust_image(
  data : Bytes,
  root_extent : Int32,
  root_size : Int32,
) -> IsoImage {
  IsoImage::{
    data,
    volume_id: "ROBUST",
    block_size: 2048,
    volume_space_size: 4,
    root: DirectoryRecord::{
      extent: root_extent,
      size: root_size,
      flags: 2,
      name: "",
      date: date_fixture(),
      system_use: Bytes::new(0),
      posix_mode: None,
      symlink_target: None,
    },
    joliet_root: None,
    joliet_level: 0,
    rock_ridge: false,
  }
}

///|
test "block number that would overflow 32 bit is rejected, not wrapped" {
  // 2^21 * 2048 = 2^32：32 位乘法回绕成 0，回绕后会"读到第 0 块"而不是报错
  let data = Bytes::new(4 * 2048)
  let image = robust_image(data, 2097152, 2048)
  let failed = try {
    let _ = image.list_dir("/")
    false
  } catch {
    Truncated => true
    _ => false
  }
  assert_true(failed)
}

///|
test "declared size larger than the image is rejected before allocating" {
  let data = FixedArray::make(4 * 2048, b'\x00')
  // 根目录里放一条 file 记录：extent 1、大小 2^31-1（远超映像长度）
  let records : Array[Byte] = []
  for rec in make_record_flags([b'\x00'], true, 1, 2048, 0) {
    records.push(rec)
  }
  for rec in make_record_flags([b'\x01'], true, 1, 2048, 0) {
    records.push(rec)
  }
  for
    rec in make_record_flags(
      [b'H', b'U', b'G', b'E', b'.', b'B', b'X'],
      false,
      2,
      2147483647,
      0,
    ) {
    records.push(rec)
  }
  for i = 0; i < records.length(); i = i + 1 {
    data[2048 + i] = records[i]
  }
  let image = robust_image(Bytes::from_array(data[:]), 1, 2048)
  let failed = try {
    let _ = image.read_file("/HUGE.BX")
    false
  } catch {
    Truncated => true
    _ => false
  }
  assert_true(failed)
}

///|
test "directory that points back at its ancestor is stopped, not recursed forever" {
  let data = FixedArray::make(4 * 2048, b'\x00')
  let records : Array[Byte] = []
  for rec in make_record_flags([b'\x00'], true, 1, 2048, 0) {
    records.push(rec)
  }
  for rec in make_record_flags([b'\x01'], true, 1, 2048, 0) {
    records.push(rec)
  }
  // 子目录记录的 extent 指回根目录本身
  for rec in make_record_flags([b'L', b'O', b'O', b'P'], true, 1, 2048, 0) {
    records.push(rec)
  }
  for i = 0; i < records.length(); i = i + 1 {
    data[2048 + i] = records[i]
  }
  let image = robust_image(Bytes::from_array(data[:]), 1, 2048)
  let failed = try {
    let _ = image.walk("/")
    false
  } catch {
    BadDescriptor(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "record longer than 255 bytes is refused on write" {
  // 长中文名：ISO 树会截成 8.3，但 Rock Ridge 的 NM 保留原名，记录必然超 255 字节
  let long_name = "/" + "很长的文件名".repeat(40) + ".txt"
  let builder = IsoBuilder::new()
  builder.add_file(long_name, bytes_of([b'x']))
  let code = try {
    let _ = builder.build()
    "built"
  } catch {
    UnsupportedLayout(name) => name
    _ => "other-error"
  }
  assert_eq(code, "iso9660-record-too-long")
}
