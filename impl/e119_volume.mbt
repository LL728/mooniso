// 卷描述符（ECMA-119 §8）：从 LBA 16 开始的一串 2048 字节结构，
// 类型 1 = 主卷描述符（PVD），类型 2 = 补充卷描述符（Joliet 用），255 = 结束符。

///|
pub const SECTOR_SIZE : Int32 = 2048

///|
pub const VOLUME_DESCRIPTOR_START_LBA : Int32 = 16

///|
pub struct PrimaryVolumeDescriptor {
  volume_id : String
  volume_space_size : Int32
  logical_block_size : Int32
  path_table_size : Int32
  root : DirectoryRecord
}

///|
/// 读取一个 2048 字节扇区并校验卷描述符签名。
fn read_sector(data : Bytes, lba : Int32) -> ByteReader raise IsoError {
  let start = block_offset(lba, SECTOR_SIZE, data.length())
  let r = ByteReader::new(data)
  r.seek(start)
  r
}

///|
/// 扫描卷描述符链，返回 (类型, 扇区号) 列表，直到遇到结束符。
/// 结构不完整（没有结束符）视为损坏。
pub fn scan_volume_descriptors(
  data : Bytes,
) -> Array[(Int32, Int32)] raise IsoError {
  let out : Array[(Int32, Int32)] = []
  let mut lba = VOLUME_DESCRIPTOR_START_LBA
  while true {
    let r = read_sector(data, lba)
    let dtype = r.read_u8().reinterpret_as_int()
    let id = r.read_ascii(5)
    if id != "CD001" {
      raise BadSignature
    }
    let _version = r.read_u8().reinterpret_as_int()
    if dtype == 255 {
      break
    }
    if dtype != 255 {
      out.push((dtype, lba))
    }
    lba += 1
    if lba > VOLUME_DESCRIPTOR_START_LBA + 64 {
      raise BadDescriptor(dtype)
    }
  }
  out
}

///|
/// 解析主卷描述符（类型 1）。
pub fn parse_primary_volume_descriptor(
  data : Bytes,
  lba : Int32,
) -> PrimaryVolumeDescriptor raise IsoError {
  let r = read_sector(data, lba)
  let dtype = r.read_u8().reinterpret_as_int()
  if dtype != 1 {
    raise BadDescriptor(dtype)
  }
  let id = r.read_ascii(5)
  if id != "CD001" {
    raise BadSignature
  }
  let version = r.read_u8().reinterpret_as_int()
  if version != 1 {
    raise BadDescriptor(version)
  }
  r.skip(1) // 偏移 7：未使用字节
  r.skip(32) // system identifier
  let volume_id = r.read_ascii(32)
  r.skip(8)
  let volume_space_size = r.read_u32_both()
  r.skip(32)
  let _volume_set_size = r.read_u16_both()
  let _volume_sequence_number = r.read_u16_both()
  let logical_block_size = r.read_u16_both()
  let path_table_size = r.read_u32_both()
  if logical_block_size <= 0 || logical_block_size % SECTOR_SIZE != 0 {
    raise BadDescriptor(logical_block_size)
  }
  // 根目录记录固定位于 PVD 偏移 156
  r.seek(lba * SECTOR_SIZE + 156)
  let (root, _) = parse_directory_record(r)
  PrimaryVolumeDescriptor::{
    volume_id,
    volume_space_size,
    logical_block_size,
    path_table_size,
    root,
  }
}

///|
/// Joliet 补充卷描述符。
pub struct JolietDescriptor {
  level : Int32
  root : DirectoryRecord
}

///|
/// 查找 Joliet 补充卷描述符：类型 2，偏移 88 的转义序列为 %/@、%/C 或 %/E。
pub fn find_joliet_descriptor(data : Bytes) -> JolietDescriptor? raise IsoError {
  for entry in scan_volume_descriptors(data) {
    let dtype = entry.0
    let lba = entry.1
    if dtype != 2 {
      continue
    }
    let r = read_sector(data, lba)
    r.seek(lba * SECTOR_SIZE + 88)
    let b0 = r.read_u8().reinterpret_as_int()
    let b1 = r.read_u8().reinterpret_as_int()
    let b2 = r.read_u8().reinterpret_as_int()
    if b0 != 0x25 || b1 != 0x2F {
      continue
    }
    let level = if b2 == 0x40 {
      1
    } else if b2 == 0x43 {
      2
    } else if b2 == 0x45 {
      3
    } else {
      0
    }
    if level > 0 {
      let root_reader = read_sector(data, lba)
      root_reader.seek(lba * SECTOR_SIZE + 156)
      let (root, _) = parse_directory_record_in(root_reader, true)
      return Some(JolietDescriptor::{ level, root, })
    }
  }
  None
}

///|
/// 从字节流指定偏移读小端 32 位。
fn read_u32_le_at(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_uint().reinterpret_as_int() |
  (data[offset + 1].to_uint().reinterpret_as_int() << 8) |
  (data[offset + 2].to_uint().reinterpret_as_int() << 16) |
  (data[offset + 3].to_uint().reinterpret_as_int() << 24)
}
