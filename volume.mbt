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
  let start = lba * SECTOR_SIZE
  if start < 0 || start + SECTOR_SIZE > data.length() {
    raise Truncated
  }
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
/// El Torito 启动信息（从启动目录里读出的第一个启动项）。
pub struct BootInfo {
  catalog_lba : Int32
  platform_id : Int32
  bootable : Bool
  media_type : Int32
  load_segment : Int32
  sector_count : Int32
  load_lba : Int32
}

///|
/// 在卷描述符链里找启动记录卷描述符（类型 0），返回启动目录所在的逻辑块号。
pub fn find_boot_catalog_lba(data : Bytes) -> Int32? raise IsoError {
  for entry in scan_volume_descriptors(data) {
    let dtype = entry.0
    let lba = entry.1
    if dtype != 0 {
      continue
    }
    let r = read_sector(data, lba)
    // El Torito: 启动目录指针是单端小端 4 字节，不是 both-endian
    r.seek(lba * SECTOR_SIZE + 71)
    return Some(r.read_u32_le())
  }
  None
}

///|
/// 解析 El Torito 启动目录：校验项 + 第一个启动项。
pub fn parse_boot_catalog(
  data : Bytes,
  catalog_lba : Int32,
) -> BootInfo raise IsoError {
  let r = read_sector(data, catalog_lba)
  r.seek(catalog_lba * SECTOR_SIZE)
  // 校验项：0x01 + 平台号 + 24 字节标识 + 校验和(2) + 55 AA
  let header_id = r.read_u8().reinterpret_as_int()
  if header_id != 0x01 {
    raise BadDescriptor(header_id)
  }
  let platform_id = r.read_u8().reinterpret_as_int()
  r.skip(2) // 保留
  r.skip(24) // 标识串
  let _checksum = r.read_u16_le()
  let key0 = r.read_u8().reinterpret_as_int()
  let key1 = r.read_u8().reinterpret_as_int()
  if key0 != 0x55 || key1 != 0xAA {
    raise BadDescriptor(key0)
  }
  // 启动项
  let boot_indicator = r.read_u8().reinterpret_as_int()
  let media_type = r.read_u8().reinterpret_as_int()
  let load_segment = r.read_u16_le()
  let _system_type = r.read_u8().reinterpret_as_int()
  let _unused = r.read_u8().reinterpret_as_int()
  let sector_count = r.read_u16_le()
  let load_lba = r.read_u32_le()
  if boot_indicator != 0x88 && boot_indicator != 0x00 {
    raise BadDescriptor(boot_indicator)
  }
  BootInfo::{
    catalog_lba,
    platform_id,
    bootable: boot_indicator == 0x88,
    media_type,
    load_segment,
    sector_count,
    load_lba,
  }
}
