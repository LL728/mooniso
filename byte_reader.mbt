// ByteReader：定长字节流上的顺序/随机读取。
//
// ISO 9660 的数值字段大多是「both-endian」（小端 4 字节 + 大端 4 字节各一份），
// 因此这里同时提供单端与双端读取，供上层按结构体字段选择。

///|
pub struct ByteReader {
  data : Bytes
  mut pos : Int32
}

///|
pub fn ByteReader::new(data : Bytes) -> ByteReader {
  { data, pos: 0, }
}

///|
pub fn ByteReader::position(self : ByteReader) -> Int32 {
  self.pos
}

///|
pub fn ByteReader::remaining(self : ByteReader) -> Int32 {
  self.data.length() - self.pos
}

///|
pub fn ByteReader::seek(self : ByteReader, pos : Int32) -> Unit raise IsoError {
  if pos < 0 || pos > self.data.length() {
    raise Truncated
  }
  self.pos = pos
}

///|
pub fn ByteReader::skip(self : ByteReader, n : Int32) -> Unit raise IsoError {
  self.seek(self.pos + n)
}

///|
pub fn ByteReader::read_u8(self : ByteReader) -> UInt32 raise IsoError {
  if self.remaining() < 1 {
    raise Truncated
  }
  let v = self.data[self.pos].to_uint()
  self.pos += 1
  v
}

///|
pub fn ByteReader::read_u16_le(self : ByteReader) -> Int32 raise IsoError {
  let a = self.read_u8().reinterpret_as_int()
  let b = self.read_u8().reinterpret_as_int()
  a | (b << 8)
}

///|
pub fn ByteReader::read_u16_be(self : ByteReader) -> Int32 raise IsoError {
  let a = self.read_u8().reinterpret_as_int()
  let b = self.read_u8().reinterpret_as_int()
  (a << 8) | b
}

///|
pub fn ByteReader::read_u32_le(self : ByteReader) -> Int32 raise IsoError {
  let a = self.read_u8().reinterpret_as_int()
  let b = self.read_u8().reinterpret_as_int()
  let c = self.read_u8().reinterpret_as_int()
  let d = self.read_u8().reinterpret_as_int()
  a | (b << 8) | (c << 16) | (d << 24)
}

///|
pub fn ByteReader::read_u32_be(self : ByteReader) -> Int32 raise IsoError {
  let a = self.read_u8().reinterpret_as_int()
  let b = self.read_u8().reinterpret_as_int()
  let c = self.read_u8().reinterpret_as_int()
  let d = self.read_u8().reinterpret_as_int()
  (a << 24) | (b << 16) | (c << 8) | d
}

///|
/// ISO 9660 的 both-endian 4 字节整数：前 4 字节小端，后 4 字节大端。
/// 两份必须一致，否则映像结构不可信。
pub fn ByteReader::read_u32_both(self : ByteReader) -> Int32 raise IsoError {
  let le = self.read_u32_le()
  let be = self.read_u32_be()
  if le != be {
    raise BadBothEndian
  }
  le
}

///|
pub fn ByteReader::read_u16_both(self : ByteReader) -> Int32 raise IsoError {
  let le = self.read_u16_le()
  let be = self.read_u16_be()
  if le != be {
    raise BadBothEndian
  }
  le
}

///|
pub fn ByteReader::read_bytes(
  self : ByteReader,
  n : Int32,
) -> Bytes raise IsoError {
  if n < 0 || self.remaining() < n {
    raise Truncated
  }
  let out = FixedArray::make(n, b'\x00')
  for i = 0; i < n; i = i + 1 {
    out[i] = self.data[self.pos + i]
  }
  self.pos += n
  Bytes::from_array(out[:])
}

///|
/// 读取定长 ASCII 字段：遇 NUL 截断，尾部空格忽略。
pub fn ByteReader::read_ascii(
  self : ByteReader,
  n : Int32,
) -> String raise IsoError {
  let raw = self.read_bytes(n)
  let mut out = ""
  for i = 0; i < n; i = i + 1 {
    let b = raw[i].to_uint().reinterpret_as_int()
    if b == 0 {
      break
    }
    out = out + Int32::unsafe_to_char(b).to_string()
  }
  out.trim_end().to_owned()
}
