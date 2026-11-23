// 大映像的分块数据源。
//
// 为什么需要它：Bytes 的索引是 32 位，单块内存上限约 2 GiB，而 UDF 1.02 的映像与其中的文件
// 都允许 64 位长度。若读取器要求 open(data : Bytes)「先把整张映像装进内存」，6 GiB 的映像
// 就永远进不了解析器——只把输出改成 read_range 分块，绕不过这个输入上限。
//
// 因此解析器只通过 ImageSource 取数据：每次按逻辑块（2048 字节）或按文件区间取，偏移、长度、
// 越界判断全程 64 位；数据从哪来由宿主决定（内存切片、文件句柄 + seek、JS Blob.slice、
// HTTP Range 都行）。解析一张 6 GiB 映像只看几十个块，内存占用与映像大小无关。

///|
/// 64 位长度的分块数据源。
pub struct ImageSource {
  /// 映像总长度（字节，64 位）。
  total : Int64
  /// 宿主提供的读取回调：(offset, length) -> Bytes；取不到时返回空 Bytes。
  read : (Int64, Int32) -> Bytes
}

///|
/// 用宿主回调构造数据源：偏移与长度都是 64 位，块号换算由本库完成，宿主只管取字节。
pub fn ImageSource::new(
  total : Int64,
  read : (Int64, Int32) -> Bytes,
) -> ImageSource {
  ImageSource::{ total, read, }
}

///|
/// 整张映像已在内存里时使用；内部仍走同一套 64 位 read_at，不额外分配。
pub fn ImageSource::from_bytes(data : Bytes) -> ImageSource {
  let total = data.length().to_int64()
  let slice = fn(offset : Int64, length : Int32) -> Bytes {
    if offset < 0L || length < 0 || offset + length.to_int64() > total {
      Bytes::make(0, b'\x00')
    } else {
      sub_bytes(data, offset.to_int(), offset.to_int() + length)
    }
  }
  ImageSource::{ total, read: slice, }
}

///|
pub fn ImageSource::length(self : ImageSource) -> Int64 {
  self.total
}

///|
/// 读取 [offset, offset + length)：偏移与长度全程 64 位。
/// 越界、或宿主返回的字节数不足，都以 Truncated 失败——不猜读、不静默补零。
pub fn ImageSource::read_at(
  self : ImageSource,
  offset : Int64,
  length : Int32,
) -> Bytes raise IsoError {
  if offset < 0L || length < 0 {
    raise Truncated
  }
  let end = offset + length.to_int64()
  if end > self.total {
    raise Truncated
  }
  let reader = self.read
  let got = reader(offset, length)
  if got.length() < length {
    raise Truncated
  }
  got
}
