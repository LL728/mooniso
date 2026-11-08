// El Torito（Bootable CD-ROM Format Specification 1.0）
//
// 覆盖两件事：
//   读取 —— 18 号卷描述符（类型 0）里的启动目录指针 + 启动目录（校验项、默认项、UEFI section）
//   写入 —— 生成启动记录卷描述符与启动目录（校验和按规范让它求和为 0）

///|
/// El Torito 启动信息（从启动目录里读出的第一个启动项）。
pub struct BootEntry {
  platform_id : Int32
  bootable : Bool
  media_type : Int32
  sector_count : Int32
  load_lba : Int32
}

///|
pub struct BootInfo {
  catalog_lba : Int32
  platform_id : Int32
  bootable : Bool
  media_type : Int32
  load_segment : Int32
  sector_count : Int32
  load_lba : Int32
  /// 启动目录里其余条目（UEFI 等通过 section header 挂在这里）
  entries : Array[BootEntry]
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
  let entries : Array[BootEntry] = [
    BootEntry::{
      platform_id,
      bootable: boot_indicator == 0x88,
      media_type,
      sector_count,
      load_lba,
    },
  ]
  // 可选 section header：0x90（最后一个）/ 0x91（后面还有），平台号与条目数在头部
  let mut cursor = catalog_lba * SECTOR_SIZE + 64
  while cursor + 32 <= (catalog_lba + 1) * SECTOR_SIZE &&
        cursor + 32 <= data.length() {
    let header = data[cursor].to_uint().reinterpret_as_int()
    if header != 0x90 && header != 0x91 {
      break
    }
    let section_platform = data[cursor + 1].to_uint().reinterpret_as_int()
    let count = data[cursor + 2].to_uint().reinterpret_as_int() |
      (data[cursor + 3].to_uint().reinterpret_as_int() << 8)
    cursor += 32
    for _i = 0; _i < count; _i = _i + 1 {
      if cursor + 32 > data.length() {
        break
      }
      let indicator = data[cursor].to_uint().reinterpret_as_int()
      let media = data[cursor + 1].to_uint().reinterpret_as_int()
      let sectors = data[cursor + 6].to_uint().reinterpret_as_int() |
        (data[cursor + 7].to_uint().reinterpret_as_int() << 8)
      let load = read_u32_le_at(data, cursor + 8)
      entries.push(BootEntry::{
        platform_id: section_platform,
        bootable: indicator == 0x88,
        media_type: media,
        sector_count: sectors,
        load_lba: load,
      })
      cursor += 32
    }
    if header == 0x90 {
      break
    }
  }
  BootInfo::{
    catalog_lba,
    platform_id,
    bootable: boot_indicator == 0x88,
    media_type,
    load_segment,
    sector_count,
    load_lba,
    entries,
  }
}

///|
/// El Torito 启动记录卷描述符（类型 0），指向启动目录所在逻辑块。
fn boot_record_sector(catalog_lba : Int32) -> Bytes {
  let sector = FixedArray::make(SECTOR_SIZE, b'\x00')
  sector[0] = b'\x00'
  let magic = ascii_bytes("CD001")
  for i = 0; i < 5; i = i + 1 {
    sector[1 + i] = magic[i]
  }
  sector[6] = b'\x01'
  let id = ascii_bytes("EL TORITO SPECIFICATION")
  for i = 0; i < id.length(); i = i + 1 {
    sector[7 + i] = id[i]
  }
  sector[71] = (catalog_lba & 0xFF).to_byte()
  sector[72] = ((catalog_lba >> 8) & 0xFF).to_byte()
  sector[73] = ((catalog_lba >> 16) & 0xFF).to_byte()
  sector[74] = ((catalog_lba >> 24) & 0xFF).to_byte()
  Bytes::from_array(sector[:])
}

///|
/// El Torito 启动目录：校验项（含校验和）+ 默认启动项。
fn boot_catalog_sector(
  bios : (Int32, Int32)?,
  efi : (Int32, Int32)?,
  platform : Int32,
) -> Bytes {
  let sector = FixedArray::make(SECTOR_SIZE, b'\x00')
  sector[0] = b'\x01'
  // 没有 BIOS 启动项时，校验项的平台号用 EFI（0xEF）
  let header_platform = match bios {
    Some(_) => platform
    None => 0xEF
  }
  sector[1] = header_platform.to_byte()
  let id = ascii_bytes("mooniso boot")
  for i = 0; i < id.length(); i = i + 1 {
    sector[4 + i] = id[i]
  }
  // 校验和：让校验项的前 16 个小端 16 位字之和为 0
  // 0x55AA 这两个固定字节也参与求和，必须先写进去
  sector[30] = b'\x55'
  sector[31] = b'\xAA'
  let mut sum = 0
  for i = 0; i < 16; i = i + 1 {
    let lo = sector[i * 2].to_uint().reinterpret_as_int()
    let hi = sector[i * 2 + 1].to_uint().reinterpret_as_int()
    sum = (sum + (lo | (hi << 8))) & 0xFFFF
  }
  let checksum = (0x10000 - sum) & 0xFFFF
  sector[28] = (checksum & 0xFF).to_byte()
  sector[29] = ((checksum >> 8) & 0xFF).to_byte()
  // 默认启动项：可启动、无仿真、加载扇区数与加载地址
  let default_entry = match bios {
    Some(pair) => Some(pair)
    None => efi
  }
  match default_entry {
    Some(pair) => {
      let (lba, sectors) = pair
      sector[32] = b'\x88'
      sector[33] = b'\x00'
      sector[38] = (sectors & 0xFF).to_byte()
      sector[39] = ((sectors >> 8) & 0xFF).to_byte()
      sector[40] = (lba & 0xFF).to_byte()
      sector[41] = ((lba >> 8) & 0xFF).to_byte()
      sector[42] = ((lba >> 16) & 0xFF).to_byte()
      sector[43] = ((lba >> 24) & 0xFF).to_byte()
    }
    None => ()
  }
  // UEFI：section header（0x90 = 最后一个，平台 0xEF）+ 一个条目
  match (bios, efi) {
    (Some(_), Some(pair)) => {
      let (lba, sectors) = pair
      let base = 64
      sector[base] = b'\x90'
      sector[base + 1] = b'\xEF'
      sector[base + 2] = b'\x01'
      sector[base + 3] = b'\x00'
      let sid = ascii_bytes("EFI")
      for i = 0; i < sid.length(); i = i + 1 {
        sector[base + 4 + i] = sid[i]
      }
      let mut header_sum = 0
      for i = 0; i < 16; i = i + 1 {
        let lo = sector[base + i * 2].to_uint().reinterpret_as_int()
        let hi = sector[base + i * 2 + 1].to_uint().reinterpret_as_int()
        header_sum = (header_sum + (lo | (hi << 8))) & 0xFFFF
      }
      let header_checksum = (0x10000 - header_sum) & 0xFFFF
      sector[base + 28] = (header_checksum & 0xFF).to_byte()
      sector[base + 29] = ((header_checksum >> 8) & 0xFF).to_byte()
      sector[base + 32] = b'\x88'
      sector[base + 33] = b'\x00'
      sector[base + 38] = (sectors & 0xFF).to_byte()
      sector[base + 39] = ((sectors >> 8) & 0xFF).to_byte()
      sector[base + 40] = (lba & 0xFF).to_byte()
      sector[base + 41] = ((lba >> 8) & 0xFF).to_byte()
      sector[base + 42] = ((lba >> 16) & 0xFF).to_byte()
      sector[base + 43] = ((lba >> 24) & 0xFF).to_byte()
    }
    _ => ()
  }
  Bytes::from_array(sector[:])
}
