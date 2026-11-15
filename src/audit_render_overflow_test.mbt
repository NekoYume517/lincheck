// ============================================================================
// audit_render_overflow_test.mbt — 时间轴列号在大跨度 Int64 时间戳下的正确性
//
// 现象：`col_of` 旧实现用 Int64 计算 `rel * width`。`render_ops` 的画布只有
// 48 列，但中间量 `rel * 48` 在「时间跨度 > Int64::MAX / 48（≈1.9e17，纳秒
// 时钟约 6 年）」时回绕成垃圾值；`span = tmax - tmin` 在时间戳接近 Int64
// 两端时本身也会回绕成负数（触发 denom=1 分支后 rel 仍可能回绕）。结果是
// **后发生的操作被画在最左边**：不崩溃、退出码不变，但时间轴形状与同一段
// 输出里的 `[tmin..tmax]` 直接矛盾——读图的人对「操作什么时候发生」的判断
// 完全错误。与 D1（截断摘要数字失真）同族：渲染层在合法输入下产出误导图。
//
// 契约依据：README「确定性优先」/ API.md §6 的 render_timeline 输出必须按
// 时间比例画横条；`timestamp_precision_test` 已锁定解析器接受完整 Int64
// 时间戳范围——渲染层不能只对「小时间戳」正确。
//
// 断言口径：同一进程内两条先后发生的操作，后者的横条与前者之间的间隔必须
// ≥ 30 列（正确值 ≈ 42–48，缺陷值 ≈ 7）。断言留 12 列以上余量，与机器无关。
// ============================================================================

///|
/// 取渲染输出的第一行（proc 0 的横条行）。
fn audit_render_first_line(text : String) -> String {
  match text.find("\n") {
    Some(i) => text.substring(start=0, end=i)
    None => text
  }
}

///|
/// 同一进程两条先后写：后者起点的正确列号 ≈ 42，回绕后紧贴前者（列 ≈ 7）。
test "时间轴：纳秒级大跨度下横条仍按时间比例排开" {
  let ops = [
    cop(0, 0, Write(1), Ok, 1000000000000000000L, 1100000000000000000L),
    cop(1, 0, Write(2), Ok, 1800000000000000000L, 1900000000000000000L),
  ]
  let line = audit_render_first_line(render_timeline(chist(ops)))
  let idx1 = line.find("W=1").unwrap_or(-1)
  let idx2 = line.find("W=2").unwrap_or(-1)
  assert_true(idx1 >= 0)
  assert_true(idx2 >= 0)
  // opB 的起点在跨度 8/9 处 → 横条必须在右侧；回绕时它紧贴 opA。
  assert_true(idx2 - idx1 >= 30)
}

///|
/// 跨度 8e18（未溢出 span 本身，但 rel*width 溢出）：opB 正确列号 ≈ 47。
test "时间轴：接近 Int64 两端的时间戳下横条仍按时间比例排开" {
  let ops = [
    cop(0, 0, Write(1), Ok, -4000000000000000000L, -3900000000000000000L),
    cop(1, 0, Write(2), Ok, 3900000000000000000L, 4000000000000000000L),
  ]
  let line = audit_render_first_line(render_timeline(chist(ops)))
  let idx1 = line.find("W=1").unwrap_or(-1)
  let idx2 = line.find("W=2").unwrap_or(-1)
  assert_true(idx1 >= 0)
  assert_true(idx2 >= 0)
  assert_true(idx2 - idx1 >= 30)
}

///|
/// 真实跨度超出 Int64（span 回绕成负数）：必须饱和降级且保持先后顺序。
test "时间轴：真实跨度超出 Int64 时横条保序（饱和降级）" {
  let ops = [
    cop(0, 0, Write(1), Ok, -9000000000000000000L, -8900000000000000000L),
    cop(1, 0, Write(2), Ok, 8900000000000000000L, 9000000000000000000L),
  ]
  let line = audit_render_first_line(render_timeline(chist(ops)))
  let idx1 = line.find("W=1").unwrap_or(-1)
  let idx2 = line.find("W=2").unwrap_or(-1)
  assert_true(idx1 >= 0)
  assert_true(idx2 >= 0)
  assert_true(idx2 - idx1 >= 30)
}
