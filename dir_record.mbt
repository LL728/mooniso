// 目录记录（ECMA-119 §9.1）：ISO 9660 里唯一描述「文件/目录」的结构，
// 目录本身也是一串目录记录，只有 0 长度记录表示本扇区剩余部分是填充。

///|
/// 目录记录的 7 字节时间戳（§9.1.5）：
/// 年 = 字段值 + 1900，最后 1 字节是有符号的 15 分钟时区偏移。
pub struct RecordDate {
  year : Int32
  month : Int32
  day : Int32
  hour : Int32
  minute : Int32
  second : Int32
  gmt_offset_quarters : Int32
}

///|
pub fn RecordDate::to_iso_string(self : RecordDate) -> String {
  let pad = fn(n : Int32) -> String {
    if n < 10 {
      "0" + n.to_string()
    } else {
      n.to_string()
    }
  }
  self.year.to_string() +
  "-" +
  pad(self.month) +
  "-" +
  pad(self.day) +
  "T" +
  pad(self.hour) +
  ":" +
  pad(self.minute) +
  ":" +
  pad(self.second)
}

///|
/// 一条目录记录。
///
/// - extent：文件内容起始的逻辑块号（LBA），目录则是目录数据起始 LBA；
/// - size：数据长度（字节），目录则是目录数据总长度；
/// - name：去掉 `;版本号` 后的名字，目录为原始目录名；
/// - is_dir：flags 的 bit 1。
pub struct DirectoryRecord {
  extent : Int32
  size : Int32
  flags : Int32
  name : String
  date : RecordDate
  /// system use area 原始字节（Rock Ridge / SUSP 扩展放这里）；没有则为空。
  system_use : Bytes
}

///|
pub fn DirectoryRecord::is_dir(self : DirectoryRecord) -> Bool {
  (self.flags & 2) != 0
}

///|
/// flags 的 bit 7：多段文件，后面还有同名的连续记录。
pub fn DirectoryRecord::is_multi_extent(self : DirectoryRecord) -> Bool {
  (self.flags & 0x80) != 0
}

///|
/// 特殊记录：0x00 是「本目录」，0x01 是「父目录」。
pub fn DirectoryRecord::is_special(self : DirectoryRecord) -> Bool {
  self.name == "\u{0}" || self.name == "\u{1}"
}

///|
/// 去掉 ISO 9660 的 `;版本号`，并去掉「无扩展名」时残留的点号。
pub fn normalize_iso_name(raw : String) -> String {
  let mut name = raw
  match name.find(";") {
    Some(i) => name = name[:i].to_owned()
    None => ()
  }
  if name.length() > 1 && name.has_suffix(".") {
    name = name[:name.length() - 1].to_owned()
  }
  name
}

///|
/// 解码 Joliet 的 UCS-2 大端名字（含非 BMP 的代理对），遇到 NUL 结束。
pub fn decode_ucs2_be(raw : Bytes) -> String {
  let mut out = ""
  let mut i = 0
  while i + 1 < raw.length() {
    let hi = raw[i].to_uint().reinterpret_as_int()
    let lo = raw[i + 1].to_uint().reinterpret_as_int()
    let unit = (hi << 8) | lo
    i += 2
    if unit == 0 {
      break
    }
    if unit >= 0xD800 && unit <= 0xDBFF && i + 1 < raw.length() {
      let hi2 = raw[i].to_uint().reinterpret_as_int()
      let lo2 = raw[i + 1].to_uint().reinterpret_as_int()
      let unit2 = (hi2 << 8) | lo2
      if unit2 >= 0xDC00 && unit2 <= 0xDFFF {
        let combined = 0x10000 + ((unit - 0xD800) << 10) + (unit2 - 0xDC00)
        out = out + Int32::unsafe_to_char(combined).to_string()
        i += 2
        continue
      }
    }
    out = out + Int32::unsafe_to_char(unit).to_string()
  }
  out
}

///|
/// 解析一条 ISO 9660（ASCII 名字）目录记录。
pub fn parse_directory_record(
  reader : ByteReader,
) -> (DirectoryRecord, Int32) raise IsoError {
  parse_directory_record_in(reader, false)
}

///|
/// 从 reader 当前位置解析一条目录记录，返回记录本身与消耗的字节数。
///
/// `joliet` 为 true 时名字按 UCS-2 大端解码（补充卷描述符里的记录）。
/// 返回长度为 0 表示目录数据在本扇区后面是填充。
pub fn parse_directory_record_in(
  reader : ByteReader,
  joliet : Bool,
) -> (DirectoryRecord, Int32) raise IsoError {
  let start = reader.position()
  let len = reader.read_u8().reinterpret_as_int()
  if len == 0 {
    // 填充：调用方负责跳到下一个扇区
    return (
      DirectoryRecord::{
        extent: 0,
        size: 0,
        flags: 0,
        name: "",
        date: RecordDate::{
          year: 0,
          month: 0,
          day: 0,
          hour: 0,
          minute: 0,
          second: 0,
          gmt_offset_quarters: 0,
        },
        system_use: Bytes::new(0),
      },
      0,
    )
  }
  if len < 34 {
    raise BadDirectoryRecord(len)
  }
  let _ext_attr_len = reader.read_u8().reinterpret_as_int()
  let extent = reader.read_u32_both()
  let size = reader.read_u32_both()
  let year = reader.read_u8().reinterpret_as_int() + 1900
  let month = reader.read_u8().reinterpret_as_int()
  let day = reader.read_u8().reinterpret_as_int()
  let hour = reader.read_u8().reinterpret_as_int()
  let minute = reader.read_u8().reinterpret_as_int()
  let second = reader.read_u8().reinterpret_as_int()
  let gmt_raw = reader.read_u8().reinterpret_as_int()
  // 时区偏移是 8 位补码，单位 15 分钟
  let gmt = if gmt_raw >= 128 { gmt_raw - 256 } else { gmt_raw }
  let flags = reader.read_u8().reinterpret_as_int()
  let _file_unit_size = reader.read_u8().reinterpret_as_int()
  let _interleave_gap = reader.read_u8().reinterpret_as_int()
  let _volume_seq = reader.read_u16_both()
  let name_len = reader.read_u8().reinterpret_as_int()
  let name = if name_len == 1 {
    let c = reader.read_u8().reinterpret_as_int()
    if c == 0 {
      "\u{0}"
    } else {
      "\u{1}"
    }
  } else if joliet {
    normalize_iso_name(decode_ucs2_be(reader.read_bytes(name_len)))
  } else {
    normalize_iso_name(reader.read_ascii(name_len))
  }
  // 名字长度是偶数时，后面补 1 字节
  if name_len % 2 == 0 {
    reader.skip(1)
  }
  let consumed = reader.position() - start
  // system use area：Rock Ridge / SUSP 扩展就放在这里
  let system_use = if consumed < len {
    reader.read_bytes(len - consumed)
  } else {
    Bytes::new(0)
  }
  (
    DirectoryRecord::{
      extent,
      size,
      flags,
      name,
      date: RecordDate::{
        year,
        month,
        day,
        hour,
        minute,
        second,
        gmt_offset_quarters: gmt,
      },
      system_use,
    },
    len,
  )
}
