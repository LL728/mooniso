// SUSP / Rock Ridge 解析的单元测试，字节取自 pycdlib 生成的真实映像。

///|
fn susp_entry(sig : String, body : Array[Byte]) -> Array[Byte] {
  let out : Array[Byte] = []
  let s = sig.to_array()
  out.push(s[0].to_int().to_byte())
  out.push(s[1].to_int().to_byte())
  out.push((body.length() + 4).to_byte())
  out.push(b'\x01')
  for b in body {
    out.push(b)
  }
  out
}

///|
test "SL entry builds an absolute symlink target" {
  // pycdlib 真实字节：SL 体 = 00 08 00 00 04 Docs 00 04 link
  let body = [
    b'\x00', b'\x08', b'\x00', b'\x00', b'\x04', b'D', b'o', b'c', b's', b'\x00',
    b'\x04', b'l', b'i', b'n', b'k',
  ]
  let area = bytes_of(susp_entry("SL", body))
  let info = RockRidge::empty()
  parse_susp(Bytes::new(0), 2048, area, info, 0)
  assert_eq(info.symlink, Some("/Docs/link"))
}

///|
test "NM entry decodes an alternate name" {
  let body = [b'\x00', b'H', b'e', b'l', b'l', b'o', b'.', b't', b'x', b't']
  let info = RockRidge::empty()
  parse_susp(Bytes::new(0), 2048, bytes_of(susp_entry("NM", body)), info, 0)
  assert_eq(info.name, Some("Hello.txt"))
}

///|
test "RR and SP entries mark presence" {
  let info = RockRidge::empty()
  parse_susp(
    Bytes::new(0),
    2048,
    bytes_of(susp_entry("SP", [b'\xBE', b'\xEF', b'\x00'])),
    info,
    0,
  )
  assert_true(info.present)
}

///|
test "PX entry carries the POSIX mode" {
  // mode = 0o100644 (0x81A4) 的 both-endian 形式
  let body = [
    b'\xA4', b'\x81', b'\x00', b'\x00', b'\x00', b'\x00', b'\x81', b'\xA4',
  ]
  let info = RockRidge::empty()
  parse_susp(Bytes::new(0), 2048, bytes_of(susp_entry("PX", body)), info, 0)
  assert_eq(info.mode, Some(0x81A4))
}
