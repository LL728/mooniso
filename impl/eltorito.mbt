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
  // 校验项自洽：32 字节里的 16 个小端 16 位字之和必须为 0（El Torito 2.0）
  let cs_base = catalog_lba * SECTOR_SIZE
  if cs_base + SECTOR_SIZE > data.length() {
    raise Truncated
  }
  let mut header_sum = 0
  for j = 0; j < 16; j = j + 1 {
    let lo = data[cs_base + j * 2].to_uint().reinterpret_as_int()
    let hi = data[cs_base + j * 2 + 1].to_uint().reinterpret_as_int()
    header_sum = (header_sum + (lo | (hi << 8))) & 0xFFFF
  }
  if header_sum != 0 {
    raise BadDescriptor(header_sum)
  }
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
  // 启动目录可跨扇区：section 头与项各 32 字节，单扇区装不下全部入口时用下一扇区
  let catalog_end = catalog_lba * SECTOR_SIZE + 16 * SECTOR_SIZE
  while cursor + 32 <= catalog_end && cursor + 32 <= data.length() {
    let header = data[cursor].to_uint().reinterpret_as_int()
    if header != 0x90 && header != 0x91 {
      break
    }
    // 每个 section 头也是 32 字节校验项，16 个小端字之和必须为 0
    let mut section_sum = 0
    for j = 0; j < 16; j = j + 1 {
      let lo = data[cursor + j * 2].to_uint().reinterpret_as_int()
      let hi = data[cursor + j * 2 + 1].to_uint().reinterpret_as_int()
      section_sum = (section_sum + (lo | (hi << 8))) & 0xFFFF
    }
    if section_sum != 0 {
      raise BadDescriptor(section_sum)
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
  sections : Array[(Int32, Int32, Int32)],
) -> Bytes raise IsoError {
  // 启动目录固定写一扇区：默认启动项 32 字节 + 每附加段 64 字节，2048 字节最多 32 段
  if sections.length() > 32 {
    raise UnsupportedLayout("el-torito-too-many-sections")
  }
  let sector = FixedArray::make(SECTOR_SIZE, (0).to_byte())
  sector[0] = (1).to_byte()
  let mut header_platform = 0xEF
  if sections.length() > 0 {
    let first = sections[0]
    header_platform = first.0
  }
  sector[1] = header_platform.to_byte()
  let id = ascii_bytes("mooniso boot")
  for i = 0; i < id.length(); i = i + 1 {
    sector[4 + i] = id[i]
  }
  // 校验和：让校验项的前 16 个小端 16 位字之和为 0；0x55AA 也参与求和
  sector[30] = (0x55).to_byte()
  sector[31] = (0xAA).to_byte()
  let mut sum = 0
  for i = 0; i < 16; i = i + 1 {
    let lo = sector[i * 2].to_uint().reinterpret_as_int()
    let hi = sector[i * 2 + 1].to_uint().reinterpret_as_int()
    sum = (sum + (lo | (hi << 8))) & 0xFFFF
  }
  let checksum = (0x10000 - sum) & 0xFFFF
  sector[28] = (checksum & 0xFF).to_byte()
  sector[29] = ((checksum >> 8) & 0xFF).to_byte()
  // 默认启动项
  if sections.length() > 0 {
    write_boot_entry(sector, 32, sections[0])
  }
  // 追加 section：最后一个用 0x90，其余用 0x91（El Torito 多启动入口）
  let mut at = 64
  for i = 1; i < sections.length(); i = i + 1 {
    let cur = sections[i]
    let is_last = i == sections.length() - 1
    sector[at] = if is_last { (0x90).to_byte() } else { (0x91).to_byte() }
    sector[at + 1] = cur.0.to_byte()
    sector[at + 2] = (1).to_byte()
    sector[at + 3] = (0).to_byte()
    let ident = ascii_bytes("mooniso section")
    for k = 0; k < ident.length(); k = k + 1 {
      if 4 + k < 28 {
        sector[at + 4 + k] = ident[k]
      }
    }
    sector[at + 30] = (0x55).to_byte()
    sector[at + 31] = (0xAA).to_byte()
    let mut section_sum = 0
    for j = 0; j < 16; j = j + 1 {
      let lo = sector[at + j * 2].to_uint().reinterpret_as_int()
      let hi = sector[at + j * 2 + 1].to_uint().reinterpret_as_int()
      section_sum = (section_sum + (lo | (hi << 8))) & 0xFFFF
    }
    let section_checksum = (0x10000 - section_sum) & 0xFFFF
    sector[at + 28] = (section_checksum & 0xFF).to_byte()
    sector[at + 29] = ((section_checksum >> 8) & 0xFF).to_byte()
    write_boot_entry(sector, at + 32, cur)
    at = at + 64
  }
  Bytes::from_array(sector[:])
}

///|
fn write_boot_entry(
  sector : FixedArray[Byte],
  at : Int32,
  entry : (Int32, Int32, Int32),
) -> Unit {
  let lba = entry.1
  let sectors = entry.2
  sector[at] = (0x88).to_byte()
  sector[at + 1] = (0).to_byte()
  sector[at + 6] = (sectors & 0xFF).to_byte()
  sector[at + 7] = ((sectors >> 8) & 0xFF).to_byte()
  sector[at + 8] = (lba & 0xFF).to_byte()
  sector[at + 9] = ((lba >> 8) & 0xFF).to_byte()
  sector[at + 10] = ((lba >> 16) & 0xFF).to_byte()
  sector[at + 11] = ((lba >> 24) & 0xFF).to_byte()
}
