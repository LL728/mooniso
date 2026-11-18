// El Torito：多 section 写入与启动目录校验和验证。

///|
fn boot_blob(size : Int32) -> Bytes {
  Bytes::make(size, (0).to_byte())
}

///|
test "writer emits a section header for extra boot entries" {
  let builder = IsoBuilder::new()
  builder.volume_id("SECT")
  builder.add_file("/boot.bin", boot_blob(2048))
  builder.add_file("/efi.img", boot_blob(2048))
  builder.boot_image("/boot.bin", 4, 0)
  builder.add_boot_section("/efi.img", 4, 0xEF)
  let image = IsoImage::open(builder.build())
  let info = image.boot_info().unwrap()
  assert_eq(info.entries.length(), 2)
  assert_eq(info.entries[0].platform_id, 0)
  assert_eq(info.entries[1].platform_id, 0xEF)
}

///|
test "reader rejects a boot catalog with a broken validation checksum" {
  let builder = IsoBuilder::new()
  builder.volume_id("BROKEN")
  builder.add_file("/boot.bin", boot_blob(2048))
  builder.boot_image("/boot.bin", 4, 0)
  let raw = builder.build()
  let image = IsoImage::open(raw)
  let catalog = image.boot_info().unwrap().catalog_lba
  let copy = FixedArray::make(raw.length(), (0).to_byte())
  for i = 0; i < raw.length(); i = i + 1 {
    copy[i] = raw[i]
  }
  copy[catalog * 2048 + 5] = (88).to_byte()
  let broken = Bytes::from_array(copy[:])
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
test "writer refuses more boot sections than one catalog sector holds" {
  let builder = IsoBuilder::new()
  builder.volume_id("MANY")
  builder.add_file("/boot.bin", Bytes::make(2048, (0).to_byte()))
  builder.boot_image("/boot.bin", 4, 0)
  for i = 0; i < 32; i = i + 1 {
    let name = "/s" + i.to_string() + ".bin"
    builder.add_file(name, Bytes::make(512, (0).to_byte()))
    builder.add_boot_section(name, 1, 0xEF)
  }
  let reason = try {
    let _ = builder.build()
    "built"
  } catch {
    UnsupportedLayout(name) => name
    _ => "other-error"
  }
  assert_eq(reason, "el-torito-too-many-sections")
}
