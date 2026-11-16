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

///|
/// 语义与 register 相同，但可精确控制从第 N 次 apply 起变慢。
/// 这样首轮检查确定违规、后续最小化探针确定超时，不依赖机器速度或调度运气。
struct TimeoutRegister {
  applications : Array[Int32]
  fast_applications : Int32
}

///|
pub impl Model for TimeoutRegister with fn name(_self) {
  "timeout-register"
}

///|
pub impl Model for TimeoutRegister with fn init(_self) {
  [0]
}

///|
pub impl Model for TimeoutRegister with fn apply(self, state, kind) {
  self.applications[0] = self.applications[0] + 1
  if self.applications[0] > self.fast_applications {
    let until = @env.now() + 50UL
    while @env.now() < until {

    }
  }
  register_model().apply(state, kind)
}

///|
pub impl Model for TimeoutRegister with fn state_eq(_self, a, b) {
  states_equal(a, b)
}

///|
pub impl Model for TimeoutRegister with fn state_hash(_self, state) {
  poly_hash(state)
}

///|
fn timeout_pair() -> History {
  History::{
    operations: [
      Operation::{
        id: 0,
        process: 0,
        kind: Write(2),
        result: Ok,
        start: 0L,
        end: 10L,
      },
      Operation::{
        id: 1,
        process: 1,
        kind: Read,
        result: Value(0),
        start: 20L,
        end: 30L,
      },
    ],
  }
}

///|
test "minimize unknown: 后续探针超时不得伪报不存在见证" {
  let h = timeout_pair()
  let config = CheckConfig::{
    time_budget_ms: 10,
    max_states: 200000,
    allow_unknown_results: false,
  }
  // 独立 oracle 不限时：这份历史确实违规，不是把合法历史当成最小化对象。
  let unlimited = CheckConfig::{ ..config, time_budget_ms: 0, }
  assert_true(check_with(h, register_model(), unlimited) is Violation(_))
  // 首轮 check 恰好消费两次快速 apply 并得到 Violation；之后所有 probe
  // 都超过 10ms。正确结论是「最小化未完成」，不是「不存在合格见证」。
  let four_state_model = TimeoutRegister::{
    applications: [0],
    fast_applications: 2,
  }
  match minimize_outcome_opt(h, four_state_model, config, MIN_WITNESS) {
    Inconclusive(reason) => assert_true(reason.contains("超过时间预算"))
    _ => fail("后续探针 Unknown 必须保留为 Inconclusive")
  }
  // 旧 Violation 载体也必须如实写「未完成」，不能写「没有任何子集」。
  let model = TimeoutRegister::{ applications: [0], fast_applications: 2, }
  let result = minimize_with(h, model, config)
  assert_true(result.explanation.contains("检查未能给出结论"))
  assert_true(result.explanation.contains("超过时间预算"))
  assert_true(!result.explanation.contains("没有任何子集"))
}
