// ============================================================================
// lc37_explanation_bounds_test.mbt —— 「最长一致前缀」的输出不得随规模增长
//
// ## 现象
//
// `check` 判定违规时会在解释里逐条列出「最长一致前缀」：
//
//     最长一致前缀（可以按这个顺序解释）：
//       1. 操作 0 @proc 0: Write(1) Ok [0..1]
//       2. 操作 1 @proc 0: Write(2) Ok [2..3]
//       …（一共 depth 行）
//
// `depth` 就是「搜索走到的最后一个能自洽的前缀长度」，**它可以等于历史操作数**。
// 于是解释文本的字节数与输入规模成正比，两个出口都受影响：
//
//   $ lincheck check --history h.jsonl          # 文本
//   $ lincheck check --history h.jsonl --json   # explanation 字段
//
// 实测（前面 n 条顺次合法写、末尾一条读到不存在值）：
//
//     ops=101 → json 7044 字节 / 文本 13343 字节
//     ops=301 → json 21444 字节 / 文本 40943 字节
//     ops=601 → json 43246 字节 / 文本 82947 字节
//
// 这是 LC-31 / LC-32 的同族：**任何输出路径都不得与输入规模成正比且无上界**。
// 诊断命令在完全合法的历史上下不出东西（wasm 堆耗尽）是同一类失效。
//
// ## 修复方向
//
// 与 `render_witness_ops` / `order_facts` 一致：前缀清单给固定行数上界，
// 截断时如实写清「共多少 / 列了前几 / 其余去哪拿」，完整数据由
// `check --json` 的 `witness` 数组承载。

///|
/// 造一份「长前缀」违规历史：`n` 条顺次合法写 + 末尾一条读到不存在值。
///
/// 这样的历史里，前 `n` 条都能按原顺序自洽解释，搜索的最长一致前缀就是 `n`，
/// 最后一条无法解释 —— 于是解释文本的长度直接由 `n` 决定。
fn lc37_long_prefix(n : Int32) -> History {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < n {
    let t = i.to_int64() * 2L
    ops.push(Operation::{
      id: i,
      process: 0,
      kind: Write(i + 1),
      result: Ok,
      start: t,
      end: t + 1L,
    })
    i = i + 1
  }
  let t = n.to_int64() * 2L
  ops.push(Operation::{
    id: n,
    process: 0,
    kind: Read,
    result: Value(999),
    start: t,
    end: t + 1L,
  })
  History::{ operations: ops, }
}

///|
/// 跑一次 check，取回违规解释文本（非违规/未知返回空串）。
fn lc37_explanation(h : History) -> String {
  let r = check_with(h, AnyModel::Register(register_model()), CheckConfig::{
    time_budget_ms: 0,
    max_states: 200_000,
    allow_unknown_results: false,
  })
  match r {
    Violation(v) => v.explanation
    _ => ""
  }
}

///|
/// **核心断言**：前缀清单必须有固定上界，输出与历史规模脱钩。
///
/// 用三档规模（80 / 160 / 320，即 1 倍 / 2 倍 / 4 倍）比较解释文本长度。
/// 无上界时长度严格线性增长（实测修复前 6820 → 14009，正好 2 倍），这里立刻红。
///
/// 判据不是「三者逐字节相等」：截断说明里要写「共 N 个操作」「其余 M 个」，
/// 而 N/M 的**十进制位数**随规模变化（80 是两位、320 是三位），因此允许一个
/// 很小的常数级差异。无上界时差异是**成千字节**，两者量级相差三个数量级，
/// 用 `< 64` 作阈值足以区分，又不会因为记账数字变位数而误报。
test "LC-37: 违规解释的前缀清单有固定上界，不随历史规模增长" {
  let small = lc37_explanation(lc37_long_prefix(80))
  let mid = lc37_explanation(lc37_long_prefix(160))
  let big = lc37_explanation(lc37_long_prefix(320))
  // 三档都必须真的违规并给出解释（否则本测试没在测它该测的东西）
  assert_true(small.length() > 0)
  assert_true(mid.length() > 0)
  assert_true(big.length() > 0)
  // 关键：长度不得随规模增长。允许的差异只来自截断说明里的十进制位数。
  let d1 = if mid.length() > small.length() {
    mid.length() - small.length()
  } else {
    small.length() - mid.length()
  }
  let d2 = if big.length() > small.length() {
    big.length() - small.length()
  } else {
    small.length() - big.length()
  }
  assert_true(d1 < 64)
  assert_true(d2 < 64)
}

///|
/// **双向**：截断必须如实。
///
/// - 超出上界时，解释里必须出现「已截断」+ 「共 N 个操作」+ 「只列出前 K 个」，
///   且 N 是真实的前缀长度（= 历史里能自洽解释的条数）。
/// - 未超上界时，不得出现截断字样（防「无条件截断」把功能做废）。
test "LC-37: 超上界时如实截断，未超上界时不写截断" {
  let n = 320
  let big = lc37_explanation(lc37_long_prefix(n))
  assert_true(big.contains("已截断"))
  // 前缀长度 = n（前 n 条顺次写都合法）
  assert_true(big.contains("共 \{n} 个操作"))
  assert_true(big.contains("只列出前"))
  // 小规模不写截断
  let tiny = lc37_explanation(lc37_long_prefix(3))
  assert_true(tiny.length() > 0)
  assert_false(tiny.contains("已截断"))
  // 且小规模的前缀清单是完整的 3 条
  assert_true(tiny.contains("1. "))
  assert_true(tiny.contains("3. "))
}

///|
/// **整段解释**同样要有界：前缀清单只是其中一段，整段也不能随规模涨。
///
/// 这条防的是「只给前缀加了界，`无法解释的操作` / 状态转储等处又漏了一处」。
/// 用整段解释的字节数三档相等来锁。
test "LC-37: 整段违规解释的字节数与历史规模脱钩" {
  let a = lc37_explanation(lc37_long_prefix(80)).length()
  let b = lc37_explanation(lc37_long_prefix(160)).length()
  let c = lc37_explanation(lc37_long_prefix(320)).length()
  // 与上一条同口径：只允许截断说明里十进制位数带来的常数级差异
  let d_b = if b > a { b - a } else { a - b }
  let d_c = if c > a { c - a } else { a - c }
  assert_true(d_b < 64)
  assert_true(d_c < 64)
  // 绝对量级也要小：完整历史 321 条操作，解释不该到几十 KB
  assert_true(a < 8000)
}
