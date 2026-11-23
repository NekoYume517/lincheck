// ============================================================================
// audit_20261123_lib_wbtest.mbt — 2026-11-23 轮 A3（白盒）
//
// 「公开手工结构 ≠ parser 可达输入」：History / Operation 的 pub(all) 字段
// 允许库用户直接构造 parser 永远产不出的输入 —— 负/极值时间戳、乱序、
// 重复 id、start > end、全 Nil、Int64::MIN..MAX 全并发。库级 check / 
// check_with_stats 对这些输入必须仍然给出正确结论或 Unknown（3 类），
// 不得 panic、不得死循环、不得给错结论。
// 前任探针（evidence/A3-lib-check-scratch.log）4 条全绿，此处转正收编。
// ============================================================================

///|
fn lc23_op(
  id : Int32,
  process : Int32,
  kind : OpKind,
  result : OpResult,
  start : Int64,
  end : Int64,
) -> Operation {
  { id, process, kind, result, start, end, }
}

///|
fn lc23_lin(outcome : CheckOutcome) -> Bool {
  outcome is Linearizable
}

///|
test "lc23-a3: negative timestamps + unsorted + dup ids" {
  let m = AnyModel::Register(register_model())
  let cfg = CheckConfig::default()
  // 负时间戳：W=1 [-100,-90]，W=2 [-80,-70]，R->1 [-60,-50] → 违规（应读到 2）
  let bad = History::{
    operations: [
      lc23_op(0, 0, Write(1), Ok, -100L, -90L),
      lc23_op(1, 1, Write(2), Ok, -80L, -70L),
      lc23_op(2, 0, Read, Value(1), -60L, -50L),
    ],
  }
  let ok = History::{
    operations: [
      lc23_op(0, 0, Write(1), Ok, -100L, -90L),
      lc23_op(1, 1, Write(2), Ok, -80L, -70L),
      lc23_op(2, 0, Read, Value(2), -60L, -50L),
    ],
  }
  assert_false(lc23_lin(check(bad, m, cfg)))
  assert_true(lc23_lin(check(ok, m, cfg)))
  // 未排序（倒序 / 乱序）→ 结论不变
  let rev = History::{
    operations: [
      lc23_op(2, 0, Read, Value(1), -60L, -50L),
      lc23_op(1, 1, Write(2), Ok, -80L, -70L),
      lc23_op(0, 0, Write(1), Ok, -100L, -90L),
    ],
  }
  assert_false(lc23_lin(check(rev, m, cfg)))
  let rev_ok = History::{
    operations: [
      lc23_op(2, 0, Read, Value(2), -60L, -50L),
      lc23_op(1, 1, Write(2), Ok, -80L, -70L),
      lc23_op(0, 0, Write(1), Ok, -100L, -90L),
    ],
  }
  assert_true(lc23_lin(check(rev_ok, m, cfg)))
  // 重复 id（全部 id=3），违规与合法各一份
  let dup_bad = History::{
    operations: [
      lc23_op(3, 0, Write(1), Ok, 0L, 10L),
      lc23_op(3, 1, Write(2), Ok, 12L, 20L),
      lc23_op(3, 0, Read, Value(1), 30L, 40L),
    ],
  }
  let dup_ok = History::{
    operations: [
      lc23_op(3, 0, Write(1), Ok, 0L, 10L),
      lc23_op(3, 1, Write(2), Ok, 12L, 20L),
      lc23_op(3, 0, Read, Value(2), 30L, 40L),
    ],
  }
  assert_false(lc23_lin(check(dup_bad, m, cfg)))
  assert_true(lc23_lin(check(dup_ok, m, cfg)))
  // 重复 (start,id) 但内容不同：两条 W 同刻同 id，之后 R；R 读到任一值都合法，读到 3 违规
  let tie = History::{
    operations: [
      lc23_op(0, 0, Write(1), Ok, 0L, 10L),
      lc23_op(0, 1, Write(2), Ok, 0L, 10L),
      lc23_op(1, 0, Read, Value(2), 20L, 30L),
    ],
  }
  assert_true(lc23_lin(check(tie, m, cfg)))
  let tie_bad = History::{
    operations: [
      lc23_op(0, 0, Write(1), Ok, 0L, 10L),
      lc23_op(0, 1, Write(2), Ok, 0L, 10L),
      lc23_op(1, 0, Read, Value(3), 20L, 30L),
    ],
  }
  assert_false(lc23_lin(check(tie_bad, m, cfg)))
  // 极值时间戳：Int64::MIN..MAX 全并发 12 个写 + 1 个读到其中之一 → 合法
  let ext : Array[Operation] = []
  for i in 0..<12 {
    ext.push(
      lc23_op(
        i,
        i % 3,
        Write(i),
        Ok,
        -9223372036854775808L,
        9223372036854775807L,
      ),
    )
  }
  ext.push(
    lc23_op(12, 0, Read, Value(11), -9223372036854775808L, 9223372036854775807L),
  )
  let ext_h = History::{ operations: ext, }
  assert_true(lc23_lin(check(ext_h, m, cfg)))
  // 极值：W(5) 在 Int64::MIN 附近结束，R 在 Int64::MAX 附近读到 0 → 违规
  let ext_bad = History::{
    operations: [
      lc23_op(0, 0, Write(5), Ok, -9223372036854775808L, -9223372036854775800L),
      lc23_op(1, 1, Read, Value(0), 9223372036854775800L, 9223372036854775807L),
    ],
  }
  assert_false(lc23_lin(check(ext_bad, m, cfg)))
}

///|
test "lc23-a3: budget extremes and cache extremes agree" {
  let m = AnyModel::Register(register_model())
  let bad = History::{
    operations: [
      lc23_op(0, 0, Write(1), Ok, 0L, 10L),
      lc23_op(1, 1, Write(2), Ok, 12L, 20L),
      lc23_op(2, 0, Read, Value(1), 30L, 40L),
    ],
  }
  for budget in [-2147483648, -1, 0, 1, 2147483647] {
    for max_states in [-1, 0, 1, 200000] {
      let cfg = CheckConfig::{
        time_budget_ms: budget,
        max_states,
        allow_unknown_results: false,
      }
      let o = check(bad, m, cfg)
      // 预算 1ms 在 3 个操作上也可能撞上超时（机器负载），只要求「不得判成 Linearizable」
      if o is Linearizable {
        println(
          "budget=\{budget} max_states=\{max_states} → Linearizable (!!)",
        )
        assert_true(false)
      }
      if o is Unknown(r) {
        println("budget=\{budget} max_states=\{max_states} → Unknown: \{r}")
      }
    }
  }
  // check_with_stats 与 check 同结论
  let (o1, st) = check_with_stats(bad, register_model(), CheckConfig::default())
  assert_false(lc23_lin(o1))
  assert_eq(st.timed_out, false)
  println(
    "stats explored=\{st.explored} cache_hits=\{st.cache_hits} cache_size=\{st.cache_size}",
  )
}

///|
test "lc23-a3: deep sequential history (iterative dfs, no stack overflow)" {
  let m = AnyModel::Register(register_model())
  let n = 20000
  let ops : Array[Operation] = []
  for i in 0..<n {
    let t = i.to_int64() * 3L
    if i % 2 == 0 {
      ops.push(lc23_op(i, 0, Write(i % 7), Ok, t, t + 2L))
    } else {
      ops.push(lc23_op(i, 0, Read, Value((i - 1) % 7), t, t + 2L))
    }
  }
  let h = History::{ operations: ops, }
  let cfg = CheckConfig::{
    time_budget_ms: 60000,
    max_states: 200000,
    allow_unknown_results: false,
  }
  assert_true(lc23_lin(check(h, m, cfg)))
  // 全并发：20000 个 Read->0 全部合法（register 初值 0）
  let conc : Array[Operation] = []
  for i in 0..<n {
    conc.push(lc23_op(i, i % 4, Read, Value(0), 0L, 100L))
  }
  let hc = History::{ operations: conc, }
  assert_true(lc23_lin(check(hc, m, cfg)))
  // sort_by_start 极值不崩且保序
  let mixed : Array[Operation] = [
    lc23_op(0, 0, Write(1), Ok, 9223372036854775807L, 9223372036854775807L),
    lc23_op(1, 0, Write(1), Ok, -9223372036854775808L, -9223372036854775808L),
    lc23_op(2, 0, Write(1), Ok, 0L, 0L),
  ]
  let sorted = History::{ operations: mixed, }.sort_by_start()
  assert_eq(sorted.operations[0].id, 1)
  assert_eq(sorted.operations[1].id, 2)
  assert_eq(sorted.operations[2].id, 0)
}

///|
test "lc23-a3: allow_unknown_results text and semantics" {
  let m = AnyModel::Register(register_model())
  let h = History::{
    operations: [
      lc23_op(0, 0, Write(1), Ok, 0L, 10L),
      lc23_op(1, 0, Read, Nil, 20L, 30L),
      lc23_op(2, 0, Read, Value(1), 40L, 50L),
    ],
  }
  match check(h, m, CheckConfig::default()) {
    Unknown(r) => println("strict: \{r}")
    _ => assert_true(false)
  }
  let loose = CheckConfig::{
    time_budget_ms: 5000,
    max_states: 200000,
    allow_unknown_results: true,
  }
  assert_true(lc23_lin(check(h, m, loose)))
  // 全 Nil 历史 + 区间非法 → 区间错误优先
  let bad = History::{
    operations: [
      lc23_op(0, 0, Write(1), Ok, 10L, 0L),
      lc23_op(1, 0, Read, Nil, 20L, 30L),
    ],
  }
  match check(bad, m, loose) {
    Unknown(r) => println("loose+invalid: \{r}")
    _ => assert_true(false)
  }
  // 严格模式下区间非法 + Nil 同在：区间错误优先（先于 Nil 计数）
  match check(bad, m, CheckConfig::default()) {
    Unknown(r) => println("strict+invalid+nil: \{r}")
    _ => assert_true(false)
  }
}
