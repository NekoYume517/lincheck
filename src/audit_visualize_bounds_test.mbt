// ============================================================================
// 审计回归（2026-11-12）：`order_facts` 的输出必须与见证规模无关
//
// 现象：`visualize` 在大违规历史上直接把 wasm 堆耗尽崩溃——
//
//   $ lincheck gen --model register --processes 4 --ops 2400 --seed 7 --inject > h.jsonl
//   $ lincheck visualize --history h.jsonl        # 退出码 1 之前先打印：
//   RuntimeError: unreachable
//       at tlsf/prepareSize (wasm://wasm/...)
//       at moonbit.malloc_no_grow
//       at @moonbitlang/core/builtin.StringBuilder::grow
//
// 根因：`render_violation` 把见证子集交给 `order_facts`，后者对每对操作判断
// `happens_before` 并各写一行。顺次执行的历史里每一对都成立，于是输出是
// O(k^2) 行：k=7717 时约 5900 万行、单个 StringBuilder 撑爆 wasm 堆。
// 一条「谁来 debug 并发」的诊断命令在输入合法时崩溃，比不输出更糟。
//
// 契约：诊断输出可以有上界，但**必须说明自己截断了**，且上界不能随见证规模增长。
// ============================================================================

///|
/// n 个顺次执行的操作：`i` 的结束早于 `i+1` 的开始，所以任意 `i < j` 都满足
/// `happens_before(op[i], op[j])` —— 这是让成对事实数达到 n*(n-1) 的最短构造。
fn seq_ops(n : Int32) -> Array[Operation] {
  let out : Array[Operation] = []
  let mut i = 0
  while i < n {
    out.push(Operation::{
      id: i,
      process: i % 2,
      kind: Write(i),
      result: Ok,
      start: i.to_int64() * 10L,
      end: i.to_int64() * 10L + 1L,
    })
    i = i + 1
  }
  out
}

///|
test "order_facts output does not grow as the square of the witness" {
  let ops = seq_ops(200)
  let out = order_facts(ops)
  // 200 个顺次操作意味着 39800 对约束。截断是允许的，静默截断不允许。
  assert_true(out.contains("截断"))
  // 上界必须与 39800 行这种数量级无关：给足 20 行事实 + 一行说明的余量。
  assert_true(out.length() < 4000)
}

///|
test "order_facts still reports small witnesses in full" {
  let ops = seq_ops(6)
  let out = order_facts(ops)
  // 6 个顺次操作 = 15 对，完全放得下，不该被截断。
  assert_false(out.contains("截断"))
  assert_true(out.contains("先于"))
}
