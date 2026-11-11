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
  /// 影像合法但使用了本库不处理的布局（如 UDF 元数据分区）。
  /// 参数是布局名，供调用方与 CI 断言使用，例如 "udf-metadata-partition"。
  UnsupportedLayout(String)
}
