// 2026-11-10 审计（lincheck）回归：
//   LC-A1 gen 无可行规模上限 → 荒谬规模挂死、退出码掉出 0..4 契约
//   LC-A5 check_with_stats 的 Unknown 文案缺「已探索 N 个节点」

///|
test "LC-A1: 乘积能放进 Int32 但超出可行规模时判定为不可用" {
  // 2147483647 × 1 不越界（= Int32.MAX），但生成器按总数分配数组会挂死
  match total_ops_checked(2147483647, 1) {
    Some(_) => fail("absurd scale must be rejected")
    None => ()
  }
}

///|
test "LC-A1: 可行规模上限的边界两侧" {
  match total_ops_checked(1, MAX_GENERATED_OPS) {
    Some(n) => assert_eq(n, MAX_GENERATED_OPS)
    None => fail("limit itself must be accepted")
  }
  match total_ops_checked(1, MAX_GENERATED_OPS + 1) {
    Some(_) => fail("limit + 1 must be rejected")
    None => ()
  }
  // 正常规模仍可用
  match total_ops_checked(3, 10) {
    Some(n) => assert_eq(n, 30)
    None => fail("normal scale must be accepted")
  }
}

///|
test "LC-A1: 负数/零规模沿用既有钳制语义" {
  match total_ops_checked(0, 4) {
    Some(n) => assert_eq(n, 4) // processes < 1 钳制为 1
    None => fail("processes=0 must clamp, not reject")
  }
  match total_ops_checked(4, 0) {
    Some(n) => assert_eq(n, 0)
    None => fail("ops=0 must be an empty history")
  }
  match total_ops_checked(4, -5) {
    Some(n) => assert_eq(n, 0)
    None => fail("negative ops must clamp to 0")
  }
}

///|
test "LC-A5: check_with_stats 的超时文案与 check_with 同为带节点数" {
  // 构造「必须枚举大量排列才失败」的历史：40 个全并发写（各写不同值，
  // 状态互不相同 → 缓存无处命中）+ 1 个读，声明读到 0（不可能，因为写
  // 都在它之前完成）。搜索要穷尽排列才会否证，1ms 预算必然超时。
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 40 {
    let op = Operation::{
      id: i,
      process: i % 4,
      start: 0L,
      end: 1000L,
      kind: OpKind::Write(i + 1),
      result: OpResult::Ok,
    }
    ops.push(op)
    i = i + 1
  }
  ops.push(Operation::{
    id: 40,
    process: 0,
    start: 0L,
    end: 1000L,
    kind: OpKind::Read,
    result: OpResult::Value(0),
  })
  let history = History::{ operations: ops, }
  let config = CheckConfig::{
    time_budget_ms: 1,
    max_states: 0,
    allow_unknown_results: false,
  }
  let (outcome, _) = check_with_stats(history, register_model(), config)
  match outcome {
    Unknown(reason) => assert_true(reason.contains("已探索"))
    _ =>
      fail(
        "40 distinct concurrent writes + impossible read with 1ms must time out",
      )
  }
}
