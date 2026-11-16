// ============================================================================
// 最小化探针的 Unknown 三态回归
//
// Unknown 只表示「这次检查没有结论」，既不是 Linearizable，也不是 Violation。
// 可解释性判定与最小化结语都不能把它折叠成一个确定的布尔答案。
// ============================================================================

///|
fn unknown_interval_op() -> Operation {
  Operation::{
    id: 0,
    process: 0,
    kind: Read,
    result: Value(0),
    start: 2L,
    end: 1L,
  }
}

///|
test "minimize unknown: 单操作 Unknown 不得缓存成确定合法" {
  let expl = Expl::new()
  let model = register_model()
  let config = CheckConfig::default()
  let op = unknown_interval_op()
  assert_true(probe_ops([op], model, config) is Unknown(_))
  // 保留既有 Bool API：未知不是「已证明孤立非法」，所以返回 false；
  // 但它也绝不是「已证明合法」，不得写入确定结果缓存。
  assert_true(!expl.is_illegal(op, model, config))
  assert_eq(expl.illegal.length(), 0)
}

///|
test "minimize unknown: 可解释性不得把 Unknown 当成合法单操作" {
  let expl = Expl::new()
  let model = register_model()
  let config = CheckConfig::default()
  let op = unknown_interval_op()
  // 连单操作本身的检查都是 Unknown，就无法证明整个子集满足可解释性。
  assert_true(!explainable([op], model, config, expl))
  assert_eq(expl.illegal.length(), 0)
}
