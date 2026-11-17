// 路径表读取：目录树的扁平索引必须与目录记录一致。

///|
test "path table lists directories with extent, parent and level" {
  let builder = IsoBuilder::new()
  builder.volume_id("PT")
  builder.add_directory("/Docs")
  builder.add_directory("/Docs/Sub")
  builder.add_file("/Docs/note.md", Bytes::make(1, (110).to_byte()))
  let image = IsoImage::open(builder.build())
  let table = image.path_table()
  assert_eq(table.length(), 3)
  assert_eq(table[0].extent, image.root().extent)
  assert_eq(table[0].level, 1)
  assert_eq(table[0].parent_index, 1)
  assert_eq(table[1].name, "DOCS")
  assert_eq(table[1].parent_index, 1)
  assert_eq(table[1].level, 2)
  assert_eq(table[1].extent, image.find_record("/Docs").extent)
  assert_eq(table[2].name, "SUB")
  assert_eq(table[2].parent_index, 2)
  assert_eq(table[2].level, 3)
}
