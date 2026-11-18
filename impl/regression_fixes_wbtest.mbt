// 三条缺陷的回归测试：区间读取溢出、El Torito 静默截断、L/M 路径表不一致。

///|
/// read_range 的越界判断若用 32 位加法，offset + 超大 length 会回绕为负，守卫失效。
test "read_range rejects a length that would overflow 32 bit" {
  let image = synthetic_image()
  let failed = try {
    let _ = image.read_range("/big.bin", 1, 2147483647)
    false
  } catch {
    Truncated => true
    _ => false
  }
  assert_true(failed)
}

///|
/// 启动目录里出现既非 0 填充、也非 0x90/0x91 的字节时必须报错，而不是静默截断启动项。
test "reader rejects an unknown boot catalog header instead of stopping silently" {
  let builder = IsoBuilder::new()
  builder.volume_id("BADHDR")
  builder.add_file("/boot.bin", Bytes::make(2048, (0).to_byte()))
  builder.boot_image("/boot.bin", 4, 0)
  builder.add_file("/s1.bin", Bytes::make(512, (0).to_byte()))
  builder.add_boot_section("/s1.bin", 1, 0xEF)
  let raw = builder.build()
  let catalog = IsoImage::open(raw).boot_info().unwrap().catalog_lba
  let broken = patch_bytes(raw, catalog * 2048 + 64, [0x55])
  let failed = try {
    let _ = IsoImage::open(broken).boot_info()
    false
  } catch {
    BadDescriptor(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
/// 两份路径表只字节序不同；把 M 表某条记录的 extent 改掉，validate 必须报出来。
test "validate reports L and M path tables that disagree" {
  let builder = IsoBuilder::new()
  builder.volume_id("LM")
  builder.add_directory("/Docs")
  builder.add_file("/Docs/note.txt", Bytes::make(1, (0).to_byte()))
  let raw = builder.build()
  let ok = IsoImage::open(raw).validate()
  assert_eq(ok.problems.length(), 0)
  // M 路径表 LBA 在 PVD 偏移 148（大端 4 字节）
  let pvd = 16 * 2048
  let m_lba = (raw[pvd + 148].to_uint().reinterpret_as_int() << 24) |
    (raw[pvd + 149].to_uint().reinterpret_as_int() << 16) |
    (raw[pvd + 150].to_uint().reinterpret_as_int() << 8) |
    raw[pvd + 151].to_uint().reinterpret_as_int()
  assert_true(m_lba > 0)
  // 第二条记录（根目录 1 字节名 + 1 字节补齐 = 10 字节）的 extent 最高字节
  let broken = patch_bytes(raw, m_lba * 2048 + 10 + 5, [7])
  let report = IsoImage::open(broken).validate()
  let mut found = false
  for p in report.problems {
    if p.has_prefix("L / M 路径表") {
      found = true
    }
  }
  assert_true(found)
}
