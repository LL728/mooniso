// SUSP / Rock Ridge（IEEE P1282）解析。
//
// Rock Ridge 把扩展信息塞在目录记录的 system use area 里，每条扩展是：
//   signature(2) + length(1) + version(1) + data
// 关键条目：
//   SP  存在性标记（只出现在根目录的 "." 记录里）
//   ER  扩展引用（RRIP_1991A 之类）
//   NM  替代名字（可跨多条拼接）
//   PX  POSIX 属性（mode / nlink / uid / gid / serial）
//   SL  符号链接目标
//   CE  续接区：其余条目放在映像的另一个位置

///|
pub struct RockRidge {
  /// 替代名字（NM），没有则为 None
  mut name : String?
  /// POSIX mode（PX）
  mut mode : Int32?
  /// 符号链接目标（SL），没有则为 None
  mut symlink : String?
  /// 是否真的存在 SUSP/Rock Ridge 条目
  mut present : Bool
}

///|
fn RockRidge::empty() -> RockRidge {
  { name: None, mode: None, symlink: None, present: false, }
}

///|
/// 拷贝一段字节（越界截断到合法范围）。
fn sub_bytes(data : Bytes, start : Int32, end : Int32) -> Bytes {
  let from = if start < 0 { 0 } else { start }
  let to = if end > data.length() { data.length() } else { end }
  if to <= from {
    return Bytes::new(0)
  }
  let n = to - from
  let out = FixedArray::make(n, b'\x00')
  for i = 0; i < n; i = i + 1 {
    out[i] = data[from + i]
  }
  Bytes::from_array(out[:])
}

///|
/// 从 SUSP 条目流中取一个 both-endian 32 位值（取小端那份，并校验两份一致）。
fn susp_u32_both(area : Bytes, offset : Int32) -> Int32 raise IsoError {
  if offset + 8 > area.length() {
    raise Truncated
  }
  let le = area[offset].to_uint().reinterpret_as_int() |
    (area[offset + 1].to_uint().reinterpret_as_int() << 8) |
    (area[offset + 2].to_uint().reinterpret_as_int() << 16) |
    (area[offset + 3].to_uint().reinterpret_as_int() << 24)
  let be = (area[offset + 4].to_uint().reinterpret_as_int() << 24) |
    (area[offset + 5].to_uint().reinterpret_as_int() << 16) |
    (area[offset + 6].to_uint().reinterpret_as_int() << 8) |
    area[offset + 7].to_uint().reinterpret_as_int()
  if le != be {
    raise BadBothEndian
  }
  le
}

///|
/// 解析一段 SUSP 条目流，把结果累加到 info 上。
///
/// `data` / `block_size` 用于跟随 CE 续接区；depth 限制续接层数，防止畸形映像造成死循环。
pub fn parse_susp(
  data : Bytes,
  block_size : Int32,
  area : Bytes,
  info : RockRidge,
  depth : Int32,
) -> Unit raise IsoError {
  if depth > 4 {
    return
  }
  let mut i = 0
  while i + 4 <= area.length() {
    let len = area[i + 2].to_uint().reinterpret_as_int()
    if len < 4 || i + len > area.length() {
      break
    }
    let sig0 = area[i].to_uint().reinterpret_as_int()
    let sig1 = area[i + 1].to_uint().reinterpret_as_int()
    let body = sub_bytes(area, i + 4, i + len)
    if sig0 == 0x53 && sig1 == 0x50 {
      info.present = true // SP
    } else if sig0 == 0x45 && sig1 == 0x52 {
      info.present = true // ER
    } else if sig0 == 0x52 && sig1 == 0x52 {
      info.present = true // RR
    } else if sig0 == 0x4E && sig1 == 0x4D {
      // NM
      if body.length() >= 1 {
        let flags = body[0].to_uint().reinterpret_as_int()
        if (flags & 2) != 0 {
          info.name = Some(".")
        } else if (flags & 4) != 0 {
          info.name = Some("..")
        } else {
          let text = @utf8.decode_lossy(sub_bytes(body, 1, body.length()))
          info.name = Some(
            match info.name {
              Some(existing) => existing + text
              None => text
            },
          )
        }
      }
    } else if sig0 == 0x50 && sig1 == 0x58 {
      // PX
      info.mode = Some(susp_u32_both(area, i + 4))
    } else if sig0 == 0x53 && sig1 == 0x4C {
      // SL
      if body.length() >= 1 {
        let mut target = ""
        let mut p = 1
        while p + 2 <= body.length() {
          let cflags = body[p].to_uint().reinterpret_as_int()
          let clen = body[p + 1].to_uint().reinterpret_as_int()
          if p + 2 + clen > body.length() {
            break
          }
          let component = if (cflags & 8) != 0 {
            "/"
          } else if (cflags & 2) != 0 {
            "."
          } else if (cflags & 4) != 0 {
            ".."
          } else {
            @utf8.decode_lossy(sub_bytes(body, p + 2, p + 2 + clen))
          }
          if target == "" {
            target = component
          } else if target == "/" {
            target = target + component
          } else {
            target = target + "/" + component
          }
          p = p + 2 + clen
        }
        info.symlink = Some(target)
      }
    } else if sig0 == 0x43 && sig1 == 0x45 {
      // CE
      let block = susp_u32_both(area, i + 4)
      let offset = susp_u32_both(area, i + 12)
      let clen = susp_u32_both(area, i + 20)
      // CE 的位置用 64 位算：32 位乘法回绕后可能仍落进映像范围，从而读到错误区域
      let start64 = block.to_int64() * block_size.to_int64() + offset.to_int64()
      if start64 >= 0L &&
        clen >= 0 &&
        start64 + clen.to_int64() <= data.length().to_int64() {
        let start = start64.to_int()
        parse_susp(
          data,
          block_size,
          sub_bytes(data, start, start + clen),
          info,
          depth + 1,
        )
      }
    }
    i = i + len
  }
}

///|
/// 解析一条记录的 system use area，得到 Rock Ridge 信息。
pub fn parse_rock_ridge(
  data : Bytes,
  block_size : Int32,
  system_use : Bytes,
) -> RockRidge raise IsoError {
  let info = RockRidge::empty()
  parse_susp(data, block_size, system_use, info, 0)
  info
}
