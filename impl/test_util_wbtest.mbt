// 测试公共工具：把 Array[Byte] 转成 Bytes。

///|
fn bytes_of(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(arr[:])
}
