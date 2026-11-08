// ISO 9660 读写过程中的结构化错误。
//
// 所有解析入口都以 IsoError 失败，调用方可以据此区分「结构损坏」与「找不到路径」。

///|
pub(all) suberror IsoError {
  Truncated
  BadBothEndian
  BadSignature
  BadDescriptor(Int32)
  NotFound(String)
  NotDirectory(String)
  IsDirectory(String)
  IsSymlink(String)
  /// 宿主 I/O 失败（库本身不做 I/O，由调用方转换进来）
  HostIoError(String)
  BadDirectoryRecord(Int32)
}
