// 对外只暴露"读一张光盘 / 造一张光盘"需要的东西。
//
// 实现全部在 impl/ 里：字节序、卷描述符、目录记录、SUSP、El Torito、UDF、写入器。
// 那里还有一批 pub 的底层函数（parse_directory_record / scan_volume_descriptors 等），
// 不在这里转出——它们属于"实现细节恰好可被同包调用"，不是接口承诺。

///|
pub using @impl {
  type IsoError,
  type IsoImage,
  type IsoBuilder,
  type UdfImage,
  type WalkEntry,
  type ValidationReport,
  type UdfEntry,
  type DirectoryRecord,
  type RecordDate,
  type BootInfo,
  type BootEntry,
}
