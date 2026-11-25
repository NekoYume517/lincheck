// ============================================================================
// cli37_check_witness_bounds_wbtest.mbt —— `check` 文本出口的见证清单必须有上界
//
// ## 现象
//
// `cmd_check` 的文本分支逐条打印见证操作：
//
//     $ lincheck check --history h.jsonl
//     ✗ NON-LINEARIZABLE  (1201 / 1201 个操作)
//
//     proc 0  W=1  ->  Ok  [0..1]
//     proc 0  W=2  ->  Ok  [2..3]
//     …（一共 1201 行）
//
// 见证子集可以等于整份历史，于是这段清单与输入规模成正比。实测同一形状
// （前 n 条顺次合法写 + 末尾读到不存在值）：
//
//     ops=301  → check 文本 17610 字节
//     ops=601  → check 文本 28914 字节
//     ops=1201 → check 文本 52527 字节
//
// 其余两段（`explanation` 里的一致前缀、被迫先于的操作）已由 LC-37 加了界，
// 唯独这一段漏了 —— 它与 LC-32 同一个模子：**私有拷贝绕过共享渲染器**。
// `@lib.render_witness_ops` 本来就有 `WITNESS_LIST_MAX_LINES = 200` 的上界，
// 但它的形状是 `    · 操作 N: …`，`check` 用的是 `  <op>`，所以当年没复用，
// 上界也就没跟过来。
//
// ## 修法
//
// 不删这段（形状不同，直接复用会改变 `check` 的可观测输出），但上界口径与
// `render_witness_ops` **共用同一个常量**，并如实记账。

///|
/// 造一个含 `n` 条操作的见证，供 `check_witness_text` 使用。
///
/// 操作本身的内容不重要：这里测的是**行数上界**，不是操作语义。
fn cli37_witness(n : Int32) -> @lib.Violation {
  let ops : Array[@lib.Operation] = []
  let mut i = 0
  while i < n {
    let t = i.to_int64() * 2L
    ops.push(@lib.Operation::{
      id: i,
      process: 0,
      kind: @lib.Write(i + 1),
      result: @lib.Ok,
      start: t,
      end: t + 1L,
    })
    i = i + 1
  }
  @lib.Violation::{ ops, depth: n, explanation: "", }
}

///|
/// 数文本串的行数（末尾换行不算多一行）。
fn cli37_lines(s : String) -> Int32 {
  let mut n = 0
  for ch in s.to_array() {
    if ch == '\n' {
      n = n + 1
    }
  }
  n
}

///|
/// **核心断言**：见证清单的行数与见证规模脱钩。
///
/// 用 210 / 420 / 840 三档（都超过上界 200）：无上界时行数是 210/420/840，
/// 有上界时必须恒为「200 行清单 + 1 行截断说明」。
test "cli37: check 文本见证清单的行数与见证规模脱钩" {
  let a = cli37_lines(check_witness_text(cli37_witness(210)))
  let b = cli37_lines(check_witness_text(cli37_witness(420)))
  let c = cli37_lines(check_witness_text(cli37_witness(840)))
  assert_eq(a, b)
  assert_eq(b, c)
  // 上界 + 一行截断说明
  assert_eq(a, @lib.WITNESS_LIST_MAX_LINES + 1)
}

///|
/// **反向守卫**：未超上界的见证必须完整列出，且不写截断。
///
/// 防「无条件截断」——那会把 `check` 变成一个看不全见证的废物。
test "cli37: 见证未超上界时完整列出且不写截断" {
  let tiny = check_witness_text(cli37_witness(3))
  assert_eq(cli37_lines(tiny), 3)
  assert_false(tiny.contains("已截断"))
  // 每条操作都要有它该有的内容
  assert_true(tiny.contains("W=1"))
  assert_true(tiny.contains("W=3"))
  // 恰好等于上界时，也不该截断
  let exact = check_witness_text(cli37_witness(@lib.WITNESS_LIST_MAX_LINES))
  assert_eq(cli37_lines(exact), @lib.WITNESS_LIST_MAX_LINES)
  assert_false(exact.contains("已截断"))
}

///|
/// **双向**：超上界时截断说明必须如实给出三个数（共多少 / 列了前几 / 其余几）。
test "cli37: 超上界时截断说明的三个数字如实" {
  let n = 420
  let text = check_witness_text(cli37_witness(n))
  assert_true(text.contains("已截断"))
  assert_true(text.contains("见证共 \{n} 个操作"))
  assert_true(text.contains("只列出前 \{@lib.WITNESS_LIST_MAX_LINES} 个"))
  let rest = n - @lib.WITNESS_LIST_MAX_LINES
  assert_true(text.contains("其余 \{rest} 个"))
  // 截断说明要指路：完整字段在哪
  assert_true(text.contains("check --json"))
}
