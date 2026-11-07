// 写入侧单元测试：生成映像后用本库自己读回，行为必须一致。

///|
test "builder produces an image the reader can open" {
  let builder = IsoBuilder::new()
  builder.volume_id("ROUNDTRIP")
  builder.add_file("/Hello.txt", bytes_of([b'h', b'i']))
  builder.add_directory("/Docs")
  builder.add_file("/Docs/Note.txt", bytes_of([b'n', b'o', b't', b'e']))
  let image = IsoImage::open(builder.build())
  assert_eq(image.volume_id(), "ROUNDTRIP")
  assert_eq(image.block_size(), 2048)
  let root = image.list_dir("/")
  assert_eq(root.length(), 2)
  // 目录记录按名字升序存放，这里按名字查找而不是依赖顺序
  let mut hello_size = -1
  let mut has_docs = false
  for entry in root {
    if entry.name == "Hello.txt" {
      hello_size = entry.size
    }
    if entry.name == "Docs" {
      has_docs = entry.is_dir()
    }
  }
  assert_eq(hello_size, 2)
  assert_true(has_docs)
  let docs = image.list_dir("/Docs")
  assert_eq(docs.length(), 1)
  assert_eq(docs[0].name, "Note.txt")
  let bytes = image.read_file("/Hello.txt")
  assert_eq(bytes.length(), 2)
  assert_eq(bytes[0], b'h')
  assert_eq(image.read_file("/Docs/Note.txt").length(), 4)
}

///|
test "builder keeps long and unicode names through joliet" {
  let builder = IsoBuilder::new()
  builder.volume_id("NAMES")
  let long = "a-very-long-file-name-that-level-1-cannot-hold.txt"
  builder.add_file("/" + long, bytes_of([b'x']))
  builder.add_file("/说明.txt", bytes_of([b'y']))
  let image = IsoImage::open(builder.build())
  assert_true(image.uses_joliet())
  let names : Array[String] = []
  for entry in image.list_dir("/") {
    names.push(entry.name)
  }
  let joined = names.join(",")
  assert_eq(joined.contains(long), true)
  assert_eq(joined.contains("说明.txt"), true)
}

///|
test "sort_names orders strings ascending" {
  let sorted = sort_names(["b", "a", "c", "A"])
  assert_eq(sorted.join(","), "A,a,b,c")
}

///|
test "directory records are stored in name order" {
  let builder = IsoBuilder::new()
  builder.volume_id("ORDER")
  builder.add_file("/zebra.txt", bytes_of([b'z']))
  builder.add_file("/alpha.txt", bytes_of([b'a']))
  let image = IsoImage::open(builder.build())
  let names : Array[String] = []
  for entry in image.list_dir("/") {
    names.push(entry.name)
  }
  assert_eq(names.join(","), "alpha.txt,zebra.txt")
}

///|
test "builder can produce an El Torito bootable image" {
  let builder = IsoBuilder::new()
  builder.volume_id("BOOTABLE")
  builder.add_file("/boot.bin", Bytes::make(2048, b'\x00'))
  builder.boot_image("/boot.bin", 4, 0)
  let image = IsoImage::open(builder.build())
  match image.boot_info() {
    Some(info) => {
      assert_true(info.bootable)
      assert_eq(info.platform_id, 0)
      assert_eq(info.media_type, 0)
      assert_eq(info.sector_count, 4)
      assert_true(info.load_lba > 0)
    }
    None => assert_true(false)
  }
}

///|
test "a non-bootable image reports no boot info" {
  let builder = IsoBuilder::new()
  builder.add_file("/x.txt", bytes_of([b'x']))
  let image = IsoImage::open(builder.build())
  assert_true(image.boot_info() is None)
}

///|
test "builder can add a UEFI section entry" {
  let builder = IsoBuilder::new()
  builder.volume_id("DUALBOOT")
  builder.add_file("/boot.bin", Bytes::make(2048, b'\x00'))
  builder.add_file("/efi.img", Bytes::make(4096, b'\x00'))
  builder.boot_image("/boot.bin", 4, 0)
  builder.boot_image_efi("/efi.img", 4)
  let image = IsoImage::open(builder.build())
  match image.boot_info() {
    Some(info) => {
      assert_eq(info.entries.length(), 2)
      assert_eq(info.entries[0].platform_id, 0)
      assert_eq(info.entries[1].platform_id, 0xEF)
      assert_eq(info.entries[1].sector_count, 4)
      assert_true(info.entries[1].load_lba > 0)
    }
    None => assert_true(false)
  }
}
