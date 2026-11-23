///|
test "image source reads a slice from memory within bounds" {
  let src = ImageSource::from_bytes(b"abcdefgh")
  assert_eq(src.length(), 8L)
  let got = src.read_at(2L, 3)
  assert_eq(got.length(), 3)
  assert_eq(got[0], b'c')
  assert_eq(got[2], b'e')
}

///|
test "image source rejects an out of bounds range" {
  let src = ImageSource::from_bytes(b"abcdefgh")
  let bad = try {
    let _ = src.read_at(6L, 5)
    false
  } catch {
    Truncated => true
    _ => false
  }
  assert_true(bad)
}

///|
test "image source rejects a short read from the host" {
  let src = ImageSource::new(1024L, fn(
    offset : Int64,
    length : Int32,
  ) -> Bytes {
    let _ = offset
    let _ = length
    Bytes::make(0, b'\x00')
  })
  let bad = try {
    let _ = src.read_at(0L, 16)
    false
  } catch {
    Truncated => true
    _ => false
  }
  assert_true(bad)
}

///|
/// 1 TiB 的虚拟映像：宿主只按请求的块给数据，说明解析不必把整张映像装进内存。
test "image source asks the host only for the requested chunk of a huge image" {
  let seen : Array[Int32] = []
  let src = ImageSource::new(1099511627776L, fn(
    offset : Int64,
    length : Int32,
  ) -> Bytes {
    seen.push(length)
    Bytes::make(length, (offset & 0xFFL).to_int().to_byte())
  })
  assert_eq(src.length(), 1099511627776L)
  let first = src.read_at(0L, 2048)
  assert_eq(first.length(), 2048)
  let far = src.read_at(1099511625728L, 2048)
  assert_eq(far.length(), 2048)
  assert_eq(seen.length(), 2)
  assert_eq(seen[0], 2048)
  assert_eq(seen[1], 2048)
}
