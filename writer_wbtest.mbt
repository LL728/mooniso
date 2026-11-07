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

///|
test "builder writes rock ridge symlinks" {
  let builder = IsoBuilder::new()
  builder.add_file("/hello.txt", bytes_of([b'h', b'i']))
  builder.add_symlink("/link.txt", "/hello.txt")
  let image = IsoImage::open(builder.build())
  let entries = image.list_dir("/")
  let mut found = false
  for entry in entries {
    if entry.name == "link.txt" {
      found = true
      assert_true(entry.is_symlink())
      assert_eq(entry.symlink_target, Some("/hello.txt"))
    }
  }
  assert_true(found)
}

///|
test "name level 2 keeps names up to 31 chars in the iso tree" {
  let builder = IsoBuilder::new()
  builder.name_level(2)
  let long = "a-name-longer-than-eight-chars.txt"
  builder.add_file("/" + long, bytes_of([b'x']))
  let image = IsoImage::open(builder.build())
  // 期望 ISO 树里的名字是 31 字符截断（去掉 ;1 之后），
  // 而 Joliet 视角仍能看到全名 —— 这里只验证读取到的 ISO 名确实比 8 长。
  let found = try {
    let records = image.find_records("/" + long)
    records.length() > 0
  } catch {
    _ => false
  }
  assert_true(found)
}

///|
test "rr version 112 emits a 44-byte PX with serial number" {
  let builder = IsoBuilder::new()
  builder.rr_version(112)
  builder.add_file("/hello.txt", bytes_of([b'h']))
  let image = IsoImage::open(builder.build())
  // 重新读出 . 记录，检查它的 PX 长度是 44（36+8）
  // 重新读出根目录 "." 记录，解析它的 PX
  // PX 挂在文件和目录记录上，不在 "." 上；直接查 hello.txt 的 system use
  let entry = image.find_record("/hello.txt")
  let mut px_len_ok = false
  let mut i = 0
  let area = entry.system_use
  while i + 4 <= area.length() {
    let len = area[i + 2].to_uint().reinterpret_as_int()
    if len < 4 || i + len > area.length() {
      break
    }
    if area[i].to_uint().reinterpret_as_int() == 0x50 &&
      area[i + 1].to_uint().reinterpret_as_int() == 0x58 {
      px_len_ok = len == 44
    }
    i = i + len
  }
  assert_true(px_len_ok)
}
