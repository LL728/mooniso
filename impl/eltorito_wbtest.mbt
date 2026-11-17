// El Torito 启动目录解析的单元测试（字节按规范手工构造）。

///|
fn boot_sector() -> Bytes {
  let data = FixedArray::make(2048, b'\x00')
  // 校验项
  data[0] = b'\x01' // header id
  data[1] = b'\x00' // platform: 80x86
  for i = 4; i < 28; i = i + 1 {
    data[i] = b' '
  }
  data[30] = b'\x55'
  data[31] = b'\xAA'
  // 启动项：可启动 + 无仿真 + 加载段 0x7C0 + 4 个扇区 + 加载块 26
  data[32] = b'\x88'
  data[33] = b'\x00'
  data[34] = b'\xC0'
  data[35] = b'\x07'
  data[38] = b'\x04'
  data[39] = b'\x00'
  data[40] = b'\x1A'
  // 校验项：32 字节里 16 个小端 16 位字之和必须为 0（El Torito 2.0），夹具也要满足
  let mut header_sum = 0
  for i = 0; i < 16; i = i + 1 {
    let lo = data[i * 2].to_uint().reinterpret_as_int()
    let hi = data[i * 2 + 1].to_uint().reinterpret_as_int()
    header_sum = (header_sum + (lo | (hi << 8))) & 0xFFFF
  }
  let header_checksum = (0x10000 - header_sum) & 0xFFFF
  data[28] = (header_checksum & 0xFF).to_byte()
  data[29] = ((header_checksum >> 8) & 0xFF).to_byte()
  Bytes::from_array(data[:])
}

///|
test "boot catalog yields platform, media and load address" {
  let info = parse_boot_catalog(boot_sector(), 0)
  assert_true(info.bootable)
  assert_eq(info.platform_id, 0)
  assert_eq(info.media_type, 0)
  assert_eq(info.load_segment, 0x07C0)
  assert_eq(info.sector_count, 4)
  assert_eq(info.load_lba, 26)
}

///|
test "boot catalog rejects a broken validation header" {
  let data = boot_sector()
  let broken = FixedArray::make(2048, b'\x00')
  for i = 0; i < 2048; i = i + 1 {
    broken[i] = data[i]
  }
  broken[0] = b'\x02'
  let failed = try {
    let _ = parse_boot_catalog(Bytes::from_array(broken[:]), 0)
    false
  } catch {
    BadDescriptor(_) => true
    _ => false
  }
  assert_true(failed)
}
