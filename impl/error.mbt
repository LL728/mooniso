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
  /// 请求物化的内容超过平台上限（MoonBit Bytes 索引是 32 位）。
  /// 参数是内容的真实字节数（UDF 信息长度是 64 位，可能远大于 2 GiB）。
  /// 读取大文件时改用 read_range 分块读取。
  PayloadTooLarge(Int64)
}
