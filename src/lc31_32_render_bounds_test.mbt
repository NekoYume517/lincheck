// ============================================================================
// lc31_32_render_bounds_test.mbt —— 渲染输出的**两个维度**都必须有上界
// （2026-11-24 审计 LC-31 / LC-32 的回归测试）
//
// ## LC-31：时间轴的行数与列宽
//
// 现象（旧实现两个维度都没有上界）：
//
//   $ lincheck gen --model register --processes 100000 --ops 1 --seed 1 > h.jsonl
//   $ lincheck visualize --history h.jsonl | wc -l
//   100004          # 单份输出 7.1 MB，全部来自「每进程一行」
//
//   $ lincheck gen --model register --processes 1 --ops 5000 --seed 1 > f.jsonl
//   $ lincheck visualize --history f.jsonl | awk '{print length}' | sort -n | tail -1
//   30000           # 一行三万列；「1 个胖进程 + 上万个瘦进程」实测 84.5 MB
//
// 根因：画布尺寸 = 进程数 × (该进程的操作数 × 横条宽)，两个维度都不设界，
// 于是输出随**输入规模**增长。`visualize` 是诊断命令，输入完全合法却下不出
// 东西（wasm 堆耗尽 / 管道吃满）比不输出更糟。
//
// 契约：输出尺寸上界与历史规模**无关**，且截断时必须写明
// 「几个进程没画」「哪些行有操作没画」「完整数据去哪拿」。
//
// ## LC-32：见证清单的行数
//
// 现象：`check` 的清单走 `render_witness_ops`（有 200 行上界），而
// `minimize` 的清单走 `cmd/lincheck/main.mbt` 里一份**逐字节等价的私有拷贝**
// `render_ops_indented`（没有上界）。同一个文本形状两处实现，上界只能加在
// 一处，另一处必然是漏洞：`--ops 24000` 的违规历史会让 `minimize` 打出
// 两万多行。
//
// 契约：清单只有一个渲染器（本文件只锁它的上界；「只有一份实现」由
// `render_violation` 与 `cmd_minimize` 共用 `render_witness_ops` 保证）。
// ============================================================================

///|
/// n 个进程、每个进程 1 个操作 —— 让**行数**维度达到 n。
///
/// 时间戳取 `i*10 .. i*10+1`，于是任意两个进程的区间互不重叠，画出来是
/// 一条干净的阶梯，不会因为横条互相覆盖而干扰「行数」这一被测维度。
fn lc31_wide(n : Int32) -> History {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < n {
    ops.push(Operation::{
      id: i,
      process: i,
      kind: Write(i),
      result: Ok,
      start: i.to_int64() * 10L,
      end: i.to_int64() * 10L + 1L,
    })
    i = i + 1
  }
  History::{ operations: ops, }
}

///|
/// 1 个进程、n 个顺次操作 —— 让**列宽**维度达到 n。
///
/// 每个操作占 `label + 2` 列，顺次排开不重叠，所以旧实现的单行宽度
/// ≈ n × (label + 2)（n=5000 时约 30000 列）。
fn lc31_fat(n : Int32) -> History {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < n {
    ops.push(Operation::{
      id: i,
      process: 0,
      kind: Write(i % 7),
      result: Ok,
      start: i.to_int64() * 10L,
      end: i.to_int64() * 10L + 8L,
    })
    i = i + 1
  }
  History::{ operations: ops, }
}

///|
/// 空串也算一行（`split` 的尾部），故上界里留一个空位的余量。
fn lc31_lines(s : String) -> Array[StringView] {
  s.split("\n").collect()
}

///|
/// 行数上界必须与进程数脱钩。
///
/// 200 个进程：旧实现输出 204 行（200 行 + 轴 + 空行），新实现固定
/// 64 行 + 轴 + 至多 2 行说明。断言同时钉住**截断说明里的三个数字都是真的**
/// （共多少进程 / 画了前几个 / 其余几个）—— 静默截断与不截断一样坏。
test "LC-31: 时间轴行数上界与历史进程数脱钩" {
  let out = render_timeline(lc31_wide(200))
  let lines = lc31_lines(out)
  // 64 行进程 + 1 行轴 + 至多 2 行说明 + split 尾部空串
  assert_true(lines.length() <= 64 + 1 + 2 + 1)
  assert_true(
    out.contains(
      "（时间轴已截断：历史里共 200 个进程，只画出前 64 个",
    ),
  )
  // 200 - 64 = 136 个进程没有对应的行，且边界进程号写全了
  assert_true(out.contains("（proc 0..proc 63）"))
  assert_true(out.contains("其余 136 个进程没有对应的行"))
  // 截断不能替代「去哪拿完整数据」的指路
  assert_true(out.contains("`lincheck check --json` 的 witness 数组"))
}

///|
/// 列宽上界必须与「单个进程的操作数」脱钩。
///
/// 1200 个顺次操作：旧实现单行 ≈ 7000 列（每个操作 6 列左右）。新实现
/// 单行 ≤ 512 列 + 标签宽 + 边框，实测 539。这里用 600 作上界（远小于旧实现
/// 的量级，又给标签列留足余量），并额外断言**总字节数**同样与操作数脱钩。
test "LC-31: 时间轴单行宽度上界与单进程操作数脱钩" {
  let out = render_timeline(lc31_fat(1200))
  for line in lc31_lines(out) {
    assert_true(line.length() <= 600)
  }
  // 1200 个操作如果全画出来，光横条就远超这个量级；固定上界下总输出很小。
  assert_true(out.length() < 4000)
  assert_true(out.contains("（列宽上限 512 列："))
  assert_true(out.contains("未画出"))
  // 明细里的行数与「未画出 / 行尾截断」两个计数都要如实出现
  assert_true(out.contains("· proc 0：未画出"))
}

///|
/// 小历史不能因为加上界而被截断 —— 上界只在**超出**时生效。
///
/// 这条反向断言防的是「把上界实现成无条件丢弃」：只要上界生效就永远截断的
/// 实现能通过上面两个测试，却把 `visualize` 变成了废物。
test "LC-31: 小历史完整画出，无截断说明" {
  let out = render_timeline(lc31_wide(3))
  assert_false(out.contains("截断"))
  assert_false(out.contains("列宽上限"))
  assert_true(out.contains("proc 0"))
  assert_true(out.contains("proc 2"))
  // 轴标签：3 个操作的时间范围是 0..21（第三个操作 20..21）
  assert_true(out.contains("> 时间  [0..21]"))
}

///|
/// 见证清单行数上界：`render_witness_ops` 是 `check`（`render_violation`）与
/// CLI `minimize` 共用的唯一渲染器，见证子集最大可达整份历史。
///
/// 1000 个操作：旧 `minimize` 路径（私有拷贝）输出 1000 行；新实现 200 行 +
/// 一行截断说明。断言同时钉住说明里的三个数字（共多少 / 列了前几 / 其余几）。
test "LC-32: 见证清单行数与见证规模脱钩" {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 300 {
    ops.push(Operation::{
      id: i,
      process: i % 4,
      kind: Write(i),
      result: Ok,
      start: i.to_int64() * 10L,
      end: i.to_int64() * 10L + 5L,
    })
    i = i + 1
  }
  let out = render_witness_ops(ops)
  let lines = lc31_lines(out)
  // 200 行清单 + 1 行截断说明 + split 尾部空串
  assert_true(lines.length() <= 200 + 1 + 1)
  assert_true(
    out.contains(
      "（已截断：见证共 300 个操作，只列出前 200 个",
    ),
  )
  assert_true(
    out.contains(
      "其余 100 个的完整字段见 `lincheck check --json` 的 witness 数组",
    ),
  )
}

///|
/// 小见证完整列出：上界不能把正常规模的见证也砍掉。
test "LC-32: 小见证完整列出且保持既有文本形状" {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 5 {
    ops.push(Operation::{
      id: i,
      process: 0,
      kind: Write(i),
      result: Ok,
      start: i.to_int64(),
      end: i.to_int64() + 1L,
    })
    i = i + 1
  }
  let out = render_witness_ops(ops)
  assert_false(out.contains("已截断"))
  // 形状必须与旧 `render_ops_indented` 逐字节一致（`    · 操作 N: …`），
  // 否则「抽成共用渲染器」这个重构就改变了 CLI 的可观测输出。
  assert_true(out.contains("    · 操作 0: "))
  assert_true(out.contains("    · 操作 4: "))
  assert_eq(lc31_lines(out).length(), 6)
}
