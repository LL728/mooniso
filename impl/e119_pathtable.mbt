// ISO 9660 路径表（ECMA-119 9.4）的类型与字节级读取辅助。
//
// 路径表是目录树的扁平索引：按层序排列，每条记录给出目录标识符、extent 与父目录序号。
// 写入侧一直生成 L/M 两份表；读取入口在 tree.mbt 的 IsoImage::path_table。

///|
/// 路径表里的一条目录记录。
pub struct PathTableEntry {
  /// 目录标识符（根目录为空串）
  name : String
  /// 目录数据起始逻辑块号
  extent : Int32
  /// 父目录序号（1 起）
  parent_index : Int32
  /// 层级，根目录为 1
  level : Int32
}

///|
/// 路径表记录里的 32 位字段：L 表小端，M 表大端。
fn path_table_u32(data : Bytes, at : Int32, big_endian : Bool) -> Int32 {
  let b0 = data[at].to_uint().reinterpret_as_int()
  let b1 = data[at + 1].to_uint().reinterpret_as_int()
  let b2 = data[at + 2].to_uint().reinterpret_as_int()
  let b3 = data[at + 3].to_uint().reinterpret_as_int()
  if big_endian {
    (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
  } else {
    b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
  }
}

///|
fn path_table_u16(data : Bytes, at : Int32, big_endian : Bool) -> Int32 {
  let b0 = data[at].to_uint().reinterpret_as_int()
  let b1 = data[at + 1].to_uint().reinterpret_as_int()
  if big_endian {
    (b0 << 8) | b1
  } else {
    b0 | (b1 << 8)
  }
}
