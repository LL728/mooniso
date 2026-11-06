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
    if dtype != 0 {
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
