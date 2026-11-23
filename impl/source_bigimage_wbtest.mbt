// 大映像的数据源衔接案例：16 GiB 虚拟映像里读一个 6 GiB 文件的指定区间。
//
// 关键点不是 read_range 的 32 位输出上限，而是**输入**：解析器只通过 ImageSource 按块取数，
// 宿主按块号现造数据，整张映像从头到尾不进内存。

///|
fn bset_u16(buf : FixedArray[Byte], offset : Int32, value : Int32) -> Unit {
  buf[offset] = (value & 0xFF).to_byte()
  buf[offset + 1] = ((value >> 8) & 0xFF).to_byte()
}

///|
fn bset_u32(buf : FixedArray[Byte], offset : Int32, value : Int32) -> Unit {
  buf[offset] = (value & 0xFF).to_byte()
  buf[offset + 1] = ((value >> 8) & 0xFF).to_byte()
  buf[offset + 2] = ((value >> 16) & 0xFF).to_byte()
  buf[offset + 3] = ((value >> 24) & 0xFF).to_byte()
}

///|
fn bset_u64(buf : FixedArray[Byte], offset : Int32, value : Int64) -> Unit {
  let mut i = 0
  while i < 8 {
    buf[offset + i] = ((value >> (i * 8)) & 0xFFL).to_int().to_byte()
    i = i + 1
  }
}

///|
fn bset_tag(buf : FixedArray[Byte], offset : Int32, id : Int32) -> Unit {
  let mut i = 0
  while i < 16 {
    buf[offset + i] = (0).to_byte()
    i = i + 1
  }
  bset_u16(buf, offset, id)
  let mut sum = 0
  let mut j = 0
  while j < 16 {
    if j != 4 {
      sum = sum + buf[offset + j].to_uint().reinterpret_as_int()
    }
    j = j + 1
  }
  buf[offset + 4] = (sum % 256).to_byte()
}

///|
fn bset_bytes(
  buf : FixedArray[Byte],
  offset : Int32,
  values : Array[Int32],
) -> Unit {
  let mut i = 0
  for v in values {
    buf[offset + i] = v.to_byte()
    i = i + 1
  }
}

///|
fn bset_block() -> FixedArray[Byte] {
  FixedArray::make(2048, (0).to_byte())
}

///|
fn vimage_block(pairs : Array[(Int32, Bytes)], blk : Int32) -> Bytes? {
  for p in pairs {
    if p.0 == blk {
      return Some(p.1)
    }
  }
  None
}

///|
/// 造一张 16 GiB 虚拟映像的元数据块：anchor(256) → VDS(300..302) → FSD(310) → 根 FE(320)
/// → 根目录数据(321) → 大文件 FE(330)。大文件声明 6 GiB，用 7 个 short_ad 覆盖。
fn big_image_blocks() -> Array[(Int32, Bytes)] {
  let out : Array[(Int32, Bytes)] = []
  let anchor = bset_block()
  bset_tag(anchor, 0, 2)
  bset_u32(anchor, 16, 2048 * 3)
  bset_u32(anchor, 20, 300)
  out.push((256, Bytes::from_array(anchor[:])))
  let pvd = bset_block()
  bset_tag(pvd, 0, 1)
  out.push((300, Bytes::from_array(pvd[:])))
  let pd = bset_block()
  bset_tag(pd, 0, 5)
  bset_u32(pd, 188, 0)
  out.push((301, Bytes::from_array(pd[:])))
  let lvd = bset_block()
  bset_tag(lvd, 0, 6)
  bset_u32(lvd, 212, 2048)
  bset_u32(lvd, 248, 2048 * 2)
  bset_u32(lvd, 252, 310)
  bset_u32(lvd, 268, 0)
  out.push((302, Bytes::from_array(lvd[:])))
  let fsd = bset_block()
  bset_tag(fsd, 0, 256)
  bset_u32(fsd, 400, 2048)
  bset_u32(fsd, 404, 320)
  out.push((310, Bytes::from_array(fsd[:])))
  let root = bset_block()
  bset_tag(root, 0, 261)
  root[27] = (4).to_byte()
  bset_u64(root, 56, 2048L)
  bset_u32(root, 172, 8)
  bset_u32(root, 176, 2048)
  bset_u32(root, 180, 321)
  out.push((320, Bytes::from_array(root[:])))
  let dir = bset_block()
  bset_tag(dir, 0, 257)
  dir[18] = (0).to_byte()
  dir[19] = (8).to_byte()
  bset_u32(dir, 20, 2048)
  bset_u32(dir, 24, 330)
  bset_u16(dir, 36, 0)
  bset_bytes(dir, 38, [8, 66, 73, 71, 46, 66, 73, 78])
  out.push((321, Bytes::from_array(dir[:])))
  let fe = bset_block()
  bset_tag(fe, 0, 261)
  fe[27] = (1).to_byte()
  bset_u64(fe, 56, 6442450944L)
  bset_u32(fe, 172, 56)
  let mut at = 176
  let mut left = 6442450944L
  let mut loc = 4000000
  while left > 0L {
    let len = if left > 1073741823L { 1073741823L } else { left }
    bset_u32(fe, at, len.to_int())
    bset_u32(fe, at + 4, loc)
    at = at + 8
    left = left - len
    loc = loc + 524288
  }
  out.push((330, Bytes::from_array(fe[:])))
  out
}

///|
/// 输入输出案例：16 GiB 映像（来源是回调，不是 Bytes）里的 6 GiB 文件。
/// 输出 64 字节内容；宿主被请求的总字节数远小于映像大小（元数据几块 + 目标区间）。
test "udf reads a 6 GiB file inside a 16 GiB image without loading the image" {
  let total = 17179869184L
  let blocks = big_image_blocks()
  let seen : Array[Int32] = []
  let source = ImageSource::new(total, fn(
    offset : Int64,
    length : Int32,
  ) -> Bytes {
    seen.push(length)
    if offset % 2048L == 0L && length == 2048 {
      let blk = (offset / 2048L).to_int()
      match vimage_block(blocks, blk) {
        Some(b) => b
        None => Bytes::make(length, (offset & 0xFFL).to_int().to_byte())
      }
    } else {
      Bytes::make(length, (offset & 0xFFL).to_int().to_byte())
    }
  })
  let image = UdfImage::open_with_source(source)
  assert_eq(image.block_size(), 2048)
  assert_eq(image.file_size("/BIG.BIN"), 6442450944L)
  let entries = image.list_dir("/")
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].size, 6442450944L)
  let head = image.read_range("/BIG.BIN", 0L, 16)
  assert_eq(head.length(), 16)
  assert_eq(head[0], b'\x00')
  // 1 GiB 之后 101 字节：落在第 2 个 extent，绝对位置是 (4000000 + 524288) * 2048 + 101
  let chunk = image.read_range("/BIG.BIN", 1073741924L, 64)
  assert_eq(chunk.length(), 64)
  let expected = ((4524288L * 2048L + 101L) & 0xFFL).to_int().to_byte()
  assert_eq(chunk[0], expected)
  // 尾部 6 字节同样可达
  assert_eq(image.read_range("/BIG.BIN", 6442450938L, 6).length(), 6)
  let mut sum = 0
  for s in seen {
    sum = sum + s
  }
  println("host_bytes=" + sum.to_string())
  assert_true(sum > 0)
  assert_true(sum < 65536)
}
