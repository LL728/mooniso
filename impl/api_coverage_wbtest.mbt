// 补充测试：覆盖此前无直接用例的两个公开接口（moonbit-hackathon 自查发现的 14 项缺口之一）。

///|
test "RecordDate renders as an ISO 8601 timestamp" {
  let d = RecordDate::{
    year: 2026,
    month: 1,
    day: 2,
    hour: 3,
    minute: 4,
    second: 5,
    gmt_offset_quarters: 0,
  }
  assert_eq(d.to_iso_string(), "2026-01-02T03:04:05")
}

///|
test "RecordDate pads single digit month day and clock fields" {
  let d = RecordDate::{
    year: 2026,
    month: 11,
    day: 9,
    hour: 8,
    minute: 7,
    second: 6,
    gmt_offset_quarters: 0,
  }
  assert_eq(d.to_iso_string(), "2026-11-09T08:07:06")
}

///|

///|
/// 注意：IsoBuilder::new() 默认 rock_ridge = true，所以两个方向都要显式设置。
test "has_rock_ridge reports the flag the builder set" {
  let plain = IsoBuilder::new()
  plain.volume_id("PLAIN")
  plain.add_file("/a.txt", bytes_of([b'h']))
  plain.rock_ridge(false)
  assert_false(IsoImage::open(plain.build()).has_rock_ridge())
  let rr = IsoBuilder::new()
  rr.volume_id("RR")
  rr.add_file("/a.txt", bytes_of([b'h']))
  rr.rock_ridge(true)
  assert_true(IsoImage::open(rr.build()).has_rock_ridge())
}
