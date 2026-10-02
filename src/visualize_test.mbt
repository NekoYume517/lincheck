// ============================================================================
// 可视化测试（白盒）
// ============================================================================

///|
fn vis_op(
  id : Int32,
  process : Int32,
  kind : OpKind,
  result : OpResult,
  start : Int64,
  stop : Int64,
) -> Operation {
  Operation::{ id, process, kind, result, start, end: stop, }
}

///|
test "render_timeline basic shape" {
  let h = History::{
    operations: [
      vis_op(0, 0, Write(1), Ok, 0L, 10L),
      vis_op(1, 1, Write(2), Ok, 5L, 15L),
      vis_op(2, 2, Read, Value(2), 20L, 30L),
    ],
  }
  let out = render_timeline(h)
  // 三个进程各一行 + 一行时间轴
  let lines = out.split("\n").collect()
  assert_true(lines.length() >= 4)
  assert_true(out.contains("proc 0"))
  assert_true(out.contains("proc 1"))
  assert_true(out.contains("proc 2"))
  assert_true(out.contains("时间"))
  assert_true(out.contains("["))
  assert_true(out.contains("]"))
  assert_true(out.contains("+"))
}

///|
test "render_timeline carries op summaries" {
  let h = History::{
    operations: [
      vis_op(0, 0, Write(7), Ok, 0L, 10L),
      vis_op(1, 0, Read, Value(7), 12L, 20L),
    ],
  }
  let out = render_timeline(h)
  assert_true(out.contains("W=7"))
  assert_true(out.contains("R->7"))
}

///|
test "render_timeline handles empty history" {
  let out = render_timeline(History::new())
  assert_true(out.contains("空历史"))
}

///|
test "render_timeline is deterministic" {
  let h = History::{
    operations: [
      vis_op(0, 0, Write(1), Ok, 0L, 10L),
      vis_op(1, 1, Read, Value(1), 5L, 20L),
    ],
  }
  assert_eq(render_timeline(h), render_timeline(h))
}

///|
test "render_timeline same-process ops do not overlap" {
  // 同一进程内的横条必须按时间前后排开、互不覆盖
  let h = History::{
    operations: [
      vis_op(0, 0, Write(1), Ok, 0L, 10L),
      vis_op(1, 0, Write(2), Ok, 10L, 20L),
      vis_op(2, 0, Read, Value(2), 20L, 30L),
    ],
  }
  let out = render_timeline(h)
  let first = out.split("\n").collect()[0].to_owned()
  // 每个操作恰好一对括号
  let mut opens = 0
  let mut closes = 0
  for ch in first.to_array() {
    if ch == '[' {
      opens = opens + 1
    }
    if ch == ']' {
      closes = closes + 1
    }
  }
  assert_eq(opens, 3)
  assert_eq(closes, 3)
}

///|
test "render_violation lists witness and facts" {
  let all = History::{
    operations: [
      vis_op(0, 0, Write(1), Ok, 0L, 10L),
      vis_op(1, 1, Write(2), Ok, 12L, 20L),
      vis_op(2, 0, Read, Value(1), 30L, 40L),
    ],
  }
  let v = minimize(all, Register(register_model()), CheckConfig::default())
  let out = render_violation(v, all)
  assert_true(out.contains("NON-LINEARIZABLE"))
  assert_true(out.contains("见证子集"))
  assert_true(out.contains("冲突操作"))
  // 应列出硬顺序事实
  assert_true(out.contains("先于"))
}

///|
test "render_violation on clean history stays readable" {
  let clean = History::{
    operations: [
      vis_op(0, 0, Write(1), Ok, 0L, 10L),
      vis_op(1, 0, Read, Value(1), 12L, 20L),
    ],
  }
  let v = minimize(clean, Register(register_model()), CheckConfig::default())
  let out = render_violation(v, clean)
  assert_true(out.contains("NON-LINEARIZABLE"))
  assert_true(out.length() > 10)
}

///|
test "helpers" {
  inspect(repeat_char('-', 5), content="-----")
  inspect(pad_right("ab", 4), content="ab  ")
  inspect(pad_right("abcd", 2), content="abcd")
  inspect(clip("abcdef", 3), content="abc")
  inspect(clip("ab", 5), content="ab")
}

///|
test "op_summary covers all kinds" {
  inspect(op_summary(vis_op(0, 0, Write(3), Ok, 0L, 1L)), content="W=3")
  inspect(op_summary(vis_op(0, 0, Read, Value(3), 0L, 1L)), content="R->3")
  inspect(
    op_summary(vis_op(0, 0, Cas(1, 2), Bool(true), 0L, 1L)),
    content="C1>2->Y",
  )
  inspect(op_summary(vis_op(0, 0, Append(4), Ok, 0L, 1L)), content="A4")
  inspect(op_summary(vis_op(0, 0, Pop, Empty, 0L, 1L)), content="P->E")
}

///|
test "process_ids dedupes and sorts" {
  let h = History::{
    operations: [
      vis_op(0, 3, Write(1), Ok, 0L, 1L),
      vis_op(1, 1, Write(1), Ok, 0L, 1L),
      vis_op(2, 3, Read, Value(1), 2L, 3L),
      vis_op(3, 0, Read, Value(1), 2L, 3L),
    ],
  }
  let ps = process_ids(h)
  assert_eq(ps.length(), 3)
  inspect(ps[0], content="0")
  inspect(ps[1], content="1")
  inspect(ps[2], content="3")
}

///|
test "timeline with wide time span stays bounded" {
  // 极端跨度不应撑爆行宽
  let h = History::{
    operations: [
      vis_op(0, 0, Write(1), Ok, 0L, 1L),
      vis_op(1, 1, Write(2), Ok, 100000L, 100001L),
    ],
  }
  let out = render_timeline(h)
  let first = out.split("\n").collect()[0].to_owned()
  assert_true(first.length() < 400)
}
