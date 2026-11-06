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
}

///|
pub fn DirectoryRecord::is_dir(self : DirectoryRecord) -> Bool {
  (self.flags & 2) != 0
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
/// 从 reader 当前位置解析一条目录记录，返回记录本身与消耗的字节数。
/// 返回长度为 0 表示目录数据在本扇区后面是填充。
pub fn parse_directory_record(
  reader : ByteReader,
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
  } else {
    normalize_iso_name(reader.read_ascii(name_len))
  }
  // 名字长度是偶数时，后面补 1 字节
  if name_len % 2 == 0 {
    reader.skip(1)
  }
  let consumed = reader.position() - start
  // 跳过 system use area（Rock Ridge 将来在这里解析）
  if consumed < len {
    reader.skip(len - consumed)
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
    },
    len,
  )
}
