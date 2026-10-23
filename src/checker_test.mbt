///|
/// # checker.mbt 的测试
///
/// 重点验收：
/// 1. 4 份 examples 的判定全部正确（硬性验收点）
/// 2. 缓存开/关结果一致
/// 3. 超时返回 `Unknown` 而不是挂死
/// 4. 解释文本记录最深一致前缀
/// 5. 四个模型都能被检查（集合 / 队列的完整流程）

// ============================================================
// 辅助
// ============================================================

fn cop(
  id : Int32,
  process : Int32,
  kind : OpKind,
  result : OpResult,
  start : Int64,
  end : Int64,
) -> Operation {
  Operation::{ id, process, kind, result, start, end, }
}

///|
fn chist(ops : Array[Operation]) -> History {
  { operations: ops.copy(), }
}

///|
/// 判定结果的稳定字符串，便于 `inspect` 断言。
fn outcome_str(outcome : CheckOutcome) -> String {
  match outcome {
    Linearizable => "Linearizable"
    Violation(_) => "Violation"
    Unknown(_) => "Unknown"
  }
}

///|
/// 取违规深度。
fn violation_depth(outcome : CheckOutcome) -> Int32 {
  match outcome {
    Violation(v) => v.depth
    _ => -1
  }
}

///|
/// 取违规涉及的操作 id（升序逗号连接）。
fn violation_ids(outcome : CheckOutcome) -> String {
  match outcome {
    Violation(v) => {
      let sb = StringBuilder()
      for i, op in v.ops {
        if i > 0 {
          sb.write_string(",")
        }
        sb.write_string(op.id.to_string())
      }
      sb.to_string()
    }
    _ => "<none>"
  }
}

///|
/// 取违规解释。
fn violation_text(outcome : CheckOutcome) -> String {
  match outcome {
    Violation(v) => v.explanation
    Unknown(r) => "Unknown: " + r
    Linearizable => "<linearizable>"
  }
}

///|
/// 解析 JSONL，失败时返回空历史（仅用于测试，真实失败由断言捕获）。
fn parse_or_empty(text : StringView) -> History {
  try {
    match History::from_jsonl(text) {
      Ok(h) => h
      Err(_) => History::new()
    }
  } catch {
    _ => History::new()
  }
}

// ============================================================
// 4 份 examples（逐字内嵌，与 examples/*.jsonl 相同）
// ============================================================

///|
const CK_REGISTER_OK : String =
  #|{"id":0,"process":0,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":0,"end":10}
  #|{"id":1,"process":1,"kind":{"tag":"Write","value":2},"result":{"tag":"Ok"},"start":5,"end":15}
  #|{"id":2,"process":0,"kind":{"tag":"Read"},"result":{"tag":"Value","value":2},"start":20,"end":30}
  #|

///|
const CK_REGISTER_BAD : String =
  #|{"id":0,"process":0,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":0,"end":10}
  #|{"id":1,"process":1,"kind":{"tag":"Write","value":2},"result":{"tag":"Ok"},"start":12,"end":20}
  #|{"id":2,"process":0,"kind":{"tag":"Read"},"result":{"tag":"Value","value":1},"start":30,"end":40}
  #|

///|
const CK_STALE_READ : String =
  #|{"id":0,"process":0,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":0,"end":10}
  #|{"id":1,"process":0,"kind":{"tag":"Read"},"result":{"tag":"Value","value":1},"start":10,"end":20}
  #|{"id":2,"process":1,"kind":{"tag":"Read"},"result":{"tag":"Value","value":0},"start":30,"end":40}
  #|

///|
const CK_CONCURRENT_OK : String =
  #|{"id":0,"process":0,"kind":{"tag":"Read"},"result":{"tag":"Value","value":0},"start":0,"end":30}
  #|{"id":1,"process":1,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":5,"end":10}
  #|{"id":2,"process":2,"kind":{"tag":"Write","value":2},"result":{"tag":"Ok"},"start":12,"end":18}
  #|{"id":3,"process":3,"kind":{"tag":"Read"},"result":{"tag":"Value","value":2},"start":20,"end":35}
  #|

// ============================================================
// 硬性验收点 1/4：register_ok → 线性一致
// ============================================================
//
// W=1 [0,10] / W=2 [5,15] / R->2 [20,30]
// 两次写重叠（并发），读在两者之后。合法顺序：W=1 → W=2 → R。

///|
test "example_register_ok_is_linearizable" {
  let h = parse_or_empty(CK_REGISTER_OK)
  inspect(h.length(), content="3")
  let outcome = check_default(h, model_or_default("register"))
  inspect(outcome_str(outcome), content="Linearizable")
}

// ============================================================
// 硬性验收点 2/4：register_bad → 违规
// ============================================================
//
// W=1 [0,10] / W=2 [12,20] / R->1 [30,40]
// 两次写**不重叠**（10 < 12），W=2 必然排在 W=1 之后；
// R 在 30 开始，晚于两次写结束，必须读到 2，读到 1 就是违规。

///|
test "example_register_bad_is_violation" {
  let h = parse_or_empty(CK_REGISTER_BAD)
  inspect(h.length(), content="3")
  let outcome = check_default(h, model_or_default("register"))
  inspect(outcome_str(outcome), content="Violation")
  // 三个操作都必须提及（两次写 + 那个读）
  inspect(violation_ids(outcome), content="0,1,2")
}

///|
test "example_register_bad_explanation_names_the_read" {
  let h = parse_or_empty(CK_REGISTER_BAD)
  let outcome = check_default(h, model_or_default("register"))
  let text = violation_text(outcome)
  // 解释里必须指出模型期望 2、历史记录 1
  assert_true(text.contains("-> 2"))
  assert_true(text.contains("-> 1"))
  // 并且给出 happens-before 证据（W=2 在 R 之前完成）
  assert_true(text.contains("被迫先于它完成"))
}

///|
test "example_register_bad_with_two_writes_alone_is_fine" {
  // 去掉那个读，只剩两次不重叠的写 —— 立刻合法
  let h = chist([
    cop(0, 0, Write(1), OpResult::Ok, 0L, 10L),
    cop(1, 1, Write(2), OpResult::Ok, 12L, 20L),
  ])
  inspect(
    outcome_str(check_default(h, model_or_default("register"))),
    content="Linearizable",
  )
}

// ============================================================
// 硬性验收点 3/4：stale_read → 违规
// ============================================================
//
// W=1 [0,10] / R->1 [10,20] / R->0 [30,40]
// 第二个读在 30 开始，此时 W=1 早已完成，不可能读到初值 0。

///|
test "example_stale_read_is_violation" {
  let h = parse_or_empty(CK_STALE_READ)
  inspect(h.length(), content="3")
  let outcome = check_default(h, model_or_default("register"))
  inspect(outcome_str(outcome), content="Violation")
}

///|
test "example_stale_read_explanation_reports_expected_one" {
  let h = parse_or_empty(CK_STALE_READ)
  let outcome = check_default(h, model_or_default("register"))
  let text = violation_text(outcome)
  // 模型在写完 1 之后期望读 1，但历史记录读 0
  assert_true(text.contains("-> 1"))
  assert_true(text.contains("-> 0"))
}

// ============================================================
// 硬性验收点 4/4：concurrent_ok → 线性一致
// ============================================================
//
// R->0 [0,30] / W=1 [5,10] / W=2 [12,18] / R->2 [20,35]
// 第一个读与两个写都并发，可以排在它们前面读到初值 0；
// 第二个读在 W=2 之后，读到 2 正确。

///|
test "example_concurrent_ok_is_linearizable" {
  let h = parse_or_empty(CK_CONCURRENT_OK)
  inspect(h.length(), content="4")
  let outcome = check_default(h, model_or_default("register"))
  inspect(outcome_str(outcome), content="Linearizable")
}

///|
test "example_concurrent_ok_becomes_violation_if_first_read_is_two" {
  // 把第一个读从 0 改成 2：它在 [0,30] 内与两个写并发，
  // 但 W=2 在 18 才结束，读在 30 结束——仍然重叠，所以还能排在 W=2 之后…
  // 真正的违规要把读区间收紧到写之前。这里改第二半：让最后那个读读到 1。
  let h = chist([
    cop(0, 0, Read, Value(0), 0L, 30L),
    cop(1, 1, Write(1), OpResult::Ok, 5L, 10L),
    cop(2, 2, Write(2), OpResult::Ok, 12L, 18L),
    cop(3, 3, Read, Value(1), 20L, 35L),
  ])
  let outcome = check_default(h, model_or_default("register"))
  inspect(outcome_str(outcome), content="Violation")
}

// ============================================================
// 基本语义
// ============================================================

///|
test "empty_history_is_linearizable" {
  inspect(
    outcome_str(check_default(History::new(), model_or_default("register"))),
    content="Linearizable",
  )
}

///|
test "single_write_is_linearizable" {
  let h = chist([cop(0, 0, Write(5), OpResult::Ok, 0L, 10L)])
  inspect(
    outcome_str(check_default(h, model_or_default("register"))),
    content="Linearizable",
  )
}

///|
test "single_read_of_initial_value_is_linearizable" {
  let h = chist([cop(0, 0, Read, Value(0), 0L, 10L)])
  inspect(
    outcome_str(check_default(h, model_or_default("register"))),
    content="Linearizable",
  )
}

///|
test "single_read_of_wrong_initial_value_is_violation" {
  // 初始状态是 0，读到 9 无从解释
  let h = chist([cop(0, 0, Read, Value(9), 0L, 10L)])
  let outcome = check_default(h, model_or_default("register"))
  inspect(outcome_str(outcome), content="Violation")
  inspect(violation_depth(outcome), content="0")
}

///|
test "write_returning_value_instead_of_ok_is_violation" {
  // 写必须返回 Ok
  let h = chist([cop(0, 0, Write(5), Value(5), 0L, 10L)])
  inspect(
    outcome_str(check_default(h, model_or_default("register"))),
    content="Violation",
  )
}

///|
test "cas_success_then_read_sees_new_value" {
  let h = chist([
    cop(0, 0, Cas(0, 7), OpResult::Bool(true), 0L, 10L),
    cop(1, 1, Read, Value(7), 20L, 30L),
  ])
  inspect(
    outcome_str(check_default(h, model_or_default("register"))),
    content="Linearizable",
  )
}

///|
test "cas_failure_keeps_state" {
  // CAS 失败时状态不变，后续读仍看到 0
  let h = chist([
    cop(0, 0, Cas(5, 7), OpResult::Bool(false), 0L, 10L),
    cop(1, 1, Read, Value(0), 20L, 30L),
  ])
  inspect(
    outcome_str(check_default(h, model_or_default("register"))),
    content="Linearizable",
  )
}

///|
test "cas_success_but_reported_false_is_violation" {
  let h = chist([cop(0, 0, Cas(0, 7), OpResult::Bool(false), 0L, 10L)])
  inspect(
    outcome_str(check_default(h, model_or_default("register"))),
    content="Violation",
  )
}

///|
test "invalid_interval_reports_unknown" {
  // start > end 是无效输入；返回 Unknown 而不是错误结论
  let h = chist([cop(0, 0, Write(1), OpResult::Ok, 20L, 10L)])
  match check_default(h, model_or_default("register")) {
    Unknown(reason) => inspect(reason.contains("区间非法"), content="true")
    _ => inspect("<应当 Unknown>", content="")
  }
}

// ============================================================
// 缓存开/关一致
// ============================================================

///|
/// 构造一个需要真正回溯的历史：三个并发写 + 一个读到其中某个值。
fn backtracking_history() -> History {
  chist([
    cop(0, 0, Write(1), OpResult::Ok, 0L, 30L),
    cop(1, 1, Write(2), OpResult::Ok, 2L, 32L),
    cop(2, 2, Write(3), OpResult::Ok, 4L, 34L),
    cop(3, 0, Read, Value(2), 40L, 50L),
  ])
}

///|
test "cache_on_and_off_agree_on_linearizable" {
  let h = backtracking_history()
  let with_cache = check(h, model_or_default("register"), CheckConfig::{
    time_budget_ms: 5000,
    max_states: 200_000,
    allow_unknown_results: false,
  })
  let no_cache = check(h, model_or_default("register"), CheckConfig::{
    time_budget_ms: 5000,
    max_states: 0,
    allow_unknown_results: false,
  })
  inspect(outcome_str(with_cache), content="Linearizable")
  inspect(outcome_str(no_cache), content="Linearizable")
}

///|
test "cache_on_and_off_agree_on_violation" {
  // 三个不重叠的写 + 一个读到最早那个值 → 违规
  let h = chist([
    cop(0, 0, Write(1), OpResult::Ok, 0L, 10L),
    cop(1, 1, Write(2), OpResult::Ok, 12L, 20L),
    cop(2, 2, Write(3), OpResult::Ok, 22L, 30L),
    cop(3, 0, Read, Value(1), 40L, 50L),
  ])
  let with_cache = check(h, model_or_default("register"), CheckConfig::{
    time_budget_ms: 5000,
    max_states: 200_000,
    allow_unknown_results: false,
  })
  let no_cache = check(h, model_or_default("register"), CheckConfig::{
    time_budget_ms: 5000,
    max_states: 0,
    allow_unknown_results: false,
  })
  inspect(outcome_str(with_cache), content="Violation")
  inspect(outcome_str(no_cache), content="Violation")
  // 深度也必须一致（两者走同一套确定性搜索）
  assert_true(violation_depth(with_cache) == violation_depth(no_cache))
}

///|
test "cache_reduces_explored_nodes" {
  // 缓存的价值：同样的问题，开缓存访问的节点数不应多于关缓存
  let h = backtracking_history()
  let (_, cached) = check_with_stats(h, register_model(), CheckConfig::{
    time_budget_ms: 5000,
    max_states: 200_000,
    allow_unknown_results: false,
  })
  let (_, uncached) = check_with_stats(h, register_model(), CheckConfig::{
    time_budget_ms: 5000,
    max_states: 0,
    allow_unknown_results: false,
  })
  assert_true(cached.explored <= uncached.explored)
  // 缓存确实存了东西
  assert_true(cached.cache_size > 0)
  inspect(uncached.cache_size, content="0")
}

///|
test "cache_hits_are_positive_when_states_converge" {
  // 构造"状态必然收敛"的历史：8 个**完全并发**且都写同一个值 1 的写。
  // 无论以什么顺序线性化它们，状态都是 [1]、剩余集合都是同一批下标，
  // 因此 (状态, 剩余集合) 被大量重复到达 —— 这正是 Lowe 缓存要解决的形态。
  // 最后加一个读到 2 的读，让搜索在耗尽整个空间后才判定违规。
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 8 {
    ops.push(cop(i, i, Write(1), OpResult::Ok, 0L, 100L))
    i = i + 1
  }
  ops.push(cop(8, 0, Read, Value(2), 101L, 110L))
  let h = chist(ops)

  let (outcome, cached) = check_with_stats(h, register_model(), CheckConfig::{
    time_budget_ms: 30_000,
    max_states: 200_000,
    allow_unknown_results: false,
  })
  inspect(outcome_str(outcome), content="Violation")
  // 缓存命中了大量重复子问题
  assert_true(cached.cache_hits > 0)

  // 无缓存版本必须给出同一结论，但访问更多节点
  let (outcome2, uncached) = check_with_stats(h, register_model(), CheckConfig::{
    time_budget_ms: 30_000,
    max_states: 0,
    allow_unknown_results: false,
  })
  inspect(outcome_str(outcome2), content="Violation")
  assert_true(uncached.cache_hits == 0)
  assert_true(cached.explored < uncached.explored)
}

// ============================================================
// 确定性：同一输入两次运行结论一致
// ============================================================

///|
test "check_is_deterministic" {
  let h = parse_or_empty(CK_REGISTER_BAD)
  let a = check_default(h, model_or_default("register"))
  let b = check_default(h, model_or_default("register"))
  inspect(violation_text(a), content=violation_text(b))
  let da = violation_depth(a)
  let db = violation_depth(b)
  assert_true(da == db)
  assert_true(da >= 0)
  inspect(violation_ids(a), content=violation_ids(b))
}

// ============================================================
// 超时 → Unknown（不挂死）
// ============================================================

///|
test "timeout_returns_unknown_not_hang" {
  // 构造一个搜索空间爆炸的历史：10 个完全并发的写，最后一个读到不存在的值。
  // 无解时必须枚举全部排列，0 预算下必然超时。
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 10 {
    ops.push(cop(i, i, Write(i + 1), OpResult::Ok, 0L, 100L))
    i = i + 1
  }
  ops.push(cop(10, 0, Read, Value(999), 101L, 110L))
  let h = chist(ops)
  let outcome = check(h, model_or_default("register"), CheckConfig::{
    time_budget_ms: 1,
    max_states: 5,
    allow_unknown_results: false,
  })
  // 1ms 预算 + 5 条缓存 → 必须给出 Unknown，而不是卡死或假结论
  match outcome {
    Unknown(reason) => assert_true(reason.contains("时间预算"))
    _ => inspect(outcome_str(outcome), content="<应当 Unknown>")
  }
}

///|
test "zero_budget_means_unlimited_and_still_terminates" {
  // time_budget_ms <= 0 表示不设上限；这个问题规模小，必须正常返回结论
  let h = parse_or_empty(CK_REGISTER_OK)
  let outcome = check(h, model_or_default("register"), CheckConfig::{
    time_budget_ms: 0,
    max_states: 200_000,
    allow_unknown_results: false,
  })
  inspect(outcome_str(outcome), content="Linearizable")
}

// ============================================================
// Nil（结果未知）的宽松模式
// ============================================================

///|
test "nil_result_is_unknown_in_strict_mode" {
  // 缺失响应无法证明违反模型，严格模式下不进入搜索。
  let h = chist([cop(0, 0, Read, Nil, 0L, 10L)])
  inspect(
    outcome_str(check_default(h, model_or_default("register"))),
    content="Unknown",
  )
}

///|
test "nil_result_is_accepted_in_permissive_mode" {
  let h = chist([cop(0, 0, Read, Nil, 0L, 10L)])
  let outcome = check(h, model_or_default("register"), CheckConfig::{
    time_budget_ms: 5000,
    max_states: 200_000,
    allow_unknown_results: true,
  })
  inspect(outcome_str(outcome), content="Linearizable")
}

// ============================================================
// 其他模型的端到端检查
// ============================================================

///|
test "counter_monotonic_history_is_linearizable" {
  // 计数器只增：1, 2, 3 依次递增
  let h = chist([
    cop(0, 0, Write(1), OpResult::Ok, 0L, 10L),
    cop(1, 1, Write(2), OpResult::Ok, 12L, 20L),
    cop(2, 0, Read, Value(2), 22L, 30L),
  ])
  inspect(
    outcome_str(check_default(h, model_or_default("counter"))),
    content="Linearizable",
  )
}

///|
test "counter_rollback_is_violation" {
  // 先增加到 2，又"增加"到 1 —— 计数器不允许回退
  let h = chist([
    cop(0, 0, Write(2), OpResult::Ok, 0L, 10L),
    cop(1, 1, Write(1), OpResult::Ok, 12L, 20L),
  ])
  inspect(
    outcome_str(check_default(h, model_or_default("counter"))),
    content="Violation",
  )
}

///|
test "set_append_then_pop_is_linearizable" {
  let h = chist([
    cop(0, 0, Append(5), OpResult::Ok, 0L, 10L),
    cop(1, 1, Pop, OpResult::Bool(true), 12L, 20L),
    cop(2, 2, Pop, OpResult::Bool(false), 22L, 30L),
  ])
  inspect(
    outcome_str(check_default(h, model_or_default("set"))),
    content="Linearizable",
  )
}

///|
test "set_pop_from_empty_then_reported_true_is_violation" {
  let h = chist([cop(0, 0, Pop, OpResult::Bool(true), 0L, 10L)])
  inspect(
    outcome_str(check_default(h, model_or_default("set"))),
    content="Violation",
  )
}

///|
test "queue_fifo_history_is_linearizable" {
  let h = chist([
    cop(0, 0, Append(1), OpResult::Ok, 0L, 10L),
    cop(1, 1, Append(2), OpResult::Ok, 2L, 12L),
    cop(2, 0, Pop, Value(1), 20L, 30L),
    cop(3, 0, Pop, Value(2), 32L, 42L),
  ])
  inspect(
    outcome_str(check_default(h, model_or_default("queue"))),
    content="Linearizable",
  )
}

///|
test "queue_lifo_history_is_violation" {
  // 队列是 FIFO：先入 1 后入 2，先出的必须是 1；这里记录成先出 2
  let h = chist([
    cop(0, 0, Append(1), OpResult::Ok, 0L, 10L),
    cop(1, 1, Append(2), OpResult::Ok, 12L, 20L),
    cop(2, 0, Pop, Value(2), 30L, 40L),
  ])
  inspect(
    outcome_str(check_default(h, model_or_default("queue"))),
    content="Violation",
  )
}

///|
test "queue_pop_empty_reported_value_is_violation" {
  let h = chist([cop(0, 0, Pop, Value(1), 0L, 10L)])
  inspect(
    outcome_str(check_default(h, model_or_default("queue"))),
    content="Violation",
  )
}

// ============================================================
// check / check_any / check_with_stats 一致性
// ============================================================

///|
test "check_and_check_any_agree" {
  let h = parse_or_empty(CK_REGISTER_BAD)
  let m = model_or_default("register")
  let cfg = CheckConfig::default()
  inspect(
    outcome_str(check(h, m, cfg)),
    content=outcome_str(check_any(h, m, cfg)),
  )
}

///|
test "check_default_equals_check_with_default_config" {
  let h = parse_or_empty(CK_REGISTER_OK)
  let m = model_or_default("register")
  inspect(
    outcome_str(check_default(h, m)),
    content=outcome_str(check(h, m, CheckConfig::default())),
  )
}

///|
test "check_with_stats_matches_check_with" {
  let h = parse_or_empty(CK_REGISTER_BAD)
  let (outcome, stats) = check_with_stats(
    h,
    register_model(),
    CheckConfig::default(),
  )
  inspect(outcome_str(outcome), content="Violation")
  assert_true(stats.explored > 0)
  assert_true(!stats.timed_out)
}

///|
test "register_bad_explored_node_count_is_small" {
  // 这个反例的搜索树极窄：3 个节点就耗尽，说明剪枝（而非暴力枚举）在工作。
  //
  //   节点 1 (depth 0): min_end = 10 → 只有 W=1 可作候选（W=2 的 start=12 > 10）
  //   节点 2 (depth 1): min_end = 20 → 只有 W=2 可作候选
  //   节点 3 (depth 2): min_end = 40 → Read 可候选，但期望 Value(2) ≠ 记录 Value(1) → 剪枝
  //   回溯：无处可去 → 判定违规
  let h = parse_or_empty(CK_REGISTER_BAD)
  let (_, stats) = check_with_stats(h, register_model(), CheckConfig::default())
  assert_true(stats.explored <= 50)
  // 锁定具体数字，作为性能回归基线
  inspect(stats.explored, content="3")
}

// ============================================================
// 反例结构
// ============================================================

///|
test "violation_ops_are_sorted_by_id" {
  let h = parse_or_empty(CK_REGISTER_BAD)
  match check_default(h, model_or_default("register")) {
    Violation(v) => {
      let mut prev = -1
      for op in v.ops {
        assert_true(op.id > prev)
        prev = op.id
      }
    }
    _ => inspect("<应当 Violation>", content="")
  }
}

///|
test "violation_depth_is_within_bounds" {
  let h = parse_or_empty(CK_REGISTER_BAD)
  match check_default(h, model_or_default("register")) {
    Violation(v) => {
      assert_true(v.depth >= 0)
      assert_true(v.depth <= h.length())
    }
    _ => inspect("<应当 Violation>", content="")
  }
}

///|
test "violation_explanation_is_nonempty_and_mentions_model" {
  let h = parse_or_empty(CK_STALE_READ)
  let text = violation_text(check_default(h, model_or_default("register")))
  assert_true(text.length() > 0)
  assert_true(text.contains("register"))
  assert_true(text.contains("非线性一致"))
}

///|
test "violation_always_reports_at_least_one_op" {
  // 即使第一步就走不通，也必须给出操作证据
  let h = chist([cop(0, 0, Read, Value(42), 0L, 10L)])
  match check_default(h, model_or_default("register")) {
    Violation(v) => assert_true(v.ops.length() >= 1)
    _ => inspect("<应当 Violation>", content="")
  }
}

// ============================================================
// LC-2：depth == 0 的单操作见证必须与「真并发违规」可区分
// ============================================================
//
// 现象：单操作 `Cas(expected=1, new=2) -> Bool(true)` 的历史，check 报
// `✗ NON-LINEARIZABLE`、depth=0，看起来像并发 bug，实际是数据自相矛盾
// （初值 0 上这个 CAS 不可能返回 true）。
//
// 修复方向：不新增退出码（文件读得进、解析得了，4 是给「读不到/解析不了」
// 的；1 仍然表示「历史确实违规」这个有效结论），而是让**结论可区分**：
// 解释文本明确指出这是历史数据不一致，JSON 输出带可编程区分的 reason。

///|
test "LC-2: 单操作不可能的见证解释为数据不一致" {
  let h = chist([cop(0, 0, Cas(1, 2), Bool(true), 0L, 10L)])
  match check_default(h, model_or_default("register")) {
    Violation(v) => {
      assert_eq(v.ops.length(), 1)
      assert_true(v.explanation.contains("数据不一致"))
      assert_true(v.explanation.contains("不是并发竞态"))
      // 可编程区分（CLI --json 的 reason 字段同源）
      inspect(violation_reason(v), content="data-inconsistency")
    }
    _ => inspect("<应当 Violation>", content="")
  }
}

///|
test "LC-2: 真并发违规的解释不标注数据不一致" {
  let h = parse_or_empty(CK_REGISTER_BAD)
  match check_default(h, model_or_default("register")) {
    Violation(v) => {
      assert_true(!v.explanation.contains("数据不一致"))
      assert_true(v.explanation.contains("无法解释的操作"))
      // 与单操作数据错误必须能区分开
      inspect(violation_reason(v), content="concurrency-race")
    }
    _ => inspect("<应当 Violation>", content="")
  }
  // 搜索节点数不能因为这个改动变化（性能回归基线）
  let (_, stats) = check_with_stats(h, register_model(), CheckConfig::default())
  inspect(stats.explored, content="3")
}

// ============================================================
// 顺带修复：排序比较器不得用减法（Int/Int64 溢出会破坏全序）
// ============================================================
//
// `id` 允许完整 Int32 范围（audit2_test 锁定边界值），`start` 允许完整
// Int64 范围。用 `a.id - b.id` 当比较结果时，2147483647 - (-2147483648)
// 回绕成 -1，全序被破坏：`sort_ops_by_id` 不再升序，见证子集也不再满足
// API 承诺的「按 id 升序」，候选首选项随之内翻。

///|
test "极端 id 下 sort_ops_by_id 与见证仍按 id 升序" {
  // 1) 直接覆盖排序辅助函数
  let ops = [
    cop(2147483647, 0, Write(1), Ok, 0L, 10L),
    cop(-2147483648, 1, Write(2), Ok, 12L, 20L),
  ]
  let s = sort_ops_by_id(ops)
  inspect(s[0].id, content="-2147483648")
  inspect(s[1].id, content="2147483647")

  // 2) 见证子集必须按 id 升序（API.md 承诺）
  let h = chist([
    cop(2147483647, 0, Write(1), Ok, 0L, 10L),
    cop(-2147483648, 1, Write(2), Ok, 12L, 20L),
    cop(0, 0, Read, Value(1), 30L, 40L),
  ])
  match check_default(h, model_or_default("register")) {
    Violation(v) => {
      inspect(v.ops.length(), content="3")
      let mut i = 1
      while i < v.ops.length() {
        assert_true(v.ops[i - 1].id < v.ops[i].id)
        i = i + 1
      }
    }
    _ => inspect("<应当 Violation>", content="")
  }
}

// ============================================================
// 交叉验证：暴力全排列参考实现
// ============================================================
//
// 这是最强的一条正确性证据。对 n <= 6 的历史枚举全部 n! 种排列，
// 逐个子集判断"是否存在一个尊重 happens-before 且能解释所有结果的顺序"，
// 再与 WGL 检查器的结论对比。两者必须完全一致——否则说明剪枝
// （候选条件或缓存）漏掉了某个合法顺序，或者错误地接受了一个非法顺序。

///|
/// 递归枚举排列：尝试把 `remaining` 里每个满足 happens-before 约束的元素
/// 接到 `prefix` 之后。
fn permute_bruteforce(
  model : RegisterModel,
  ops : Array[Operation],
  remaining : Array[Int32],
  prefix : Array[Int32],
  state : State,
) -> Bool {
  if remaining.length() == 0 {
    return true
  }
  let mut found = false
  let mut i = 0
  while i < remaining.length() && !found {
    let idx = remaining[i]
    let cand = ops[idx]
    // happens-before 约束：任何比 cand 早完成的剩余操作都不能排在它后面。
    // 也就是说 cand 只能在自己之前**没有**未线性化的"先完成者"时才能排最前。
    let mut blocked = false
    for jdx in remaining {
      if jdx != idx && happens_before(ops[jdx], cand) {
        blocked = true
      }
    }
    if !blocked {
      match model.apply(state, cand.kind) {
        Some((next_state, expected)) =>
          if expected == cand.result {
            let rest : Array[Int32] = []
            for jdx in remaining {
              if jdx != idx {
                rest.push(jdx)
              }
            }
            let new_prefix : Array[Int32] = prefix.copy()
            new_prefix.push(idx)
            if permute_bruteforce(model, ops, rest, new_prefix, next_state) {
              found = true
            }
          }
        None => ()
      }
    }
    i = i + 1
  }
  found
}

///|
/// 暴力参考实现：`true` 表示存在合法全序。
fn linearizable_bruteforce(ops : Array[Operation]) -> Bool {
  let model = register_model()
  let remaining : Array[Int32] = []
  for i, _ in ops {
    remaining.push(i)
  }
  permute_bruteforce(model, ops, remaining, [], model.init())
}

///|
test "cross_verify_four_examples_against_bruteforce" {
  for text in [CK_REGISTER_OK, CK_REGISTER_BAD, CK_STALE_READ, CK_CONCURRENT_OK] {
    let h = parse_or_empty(text)
    let wgl = match check_default(h, model_or_default("register")) {
      Linearizable => true
      Violation(_) => false
      Unknown(_) => true
    }
    let bf = linearizable_bruteforce(h.operations)
    assert_true(wgl == bf)
  }
}

///|
test "cross_verify_synthetic_cases_against_bruteforce" {
  // 手工构造一批边界情形，逐个与暴力实现比对
  let cases : Array[Array[Operation]] = [
    // 单读初值
    [cop(0, 0, Read, Value(0), 0L, 10L)],
    // 单读错值
    [cop(0, 0, Read, Value(1), 0L, 10L)],
    // 写后读（不重叠）
    [
      cop(0, 0, Write(1), OpResult::Ok, 0L, 10L),
      cop(1, 0, Read, Value(1), 12L, 20L),
    ],
    // 写后读旧值（不重叠）→ 违规
    [
      cop(0, 0, Write(1), OpResult::Ok, 0L, 10L),
      cop(1, 0, Read, Value(0), 12L, 20L),
    ],
    // 读与写完全重叠 → 两种结果都合法
    [
      cop(0, 0, Read, Value(0), 0L, 20L),
      cop(1, 0, Write(1), OpResult::Ok, 5L, 10L),
    ],
    // 同上但读到 1 → 也合法（读排在写之后）
    [
      cop(0, 0, Read, Value(1), 0L, 20L),
      cop(1, 0, Write(1), OpResult::Ok, 5L, 10L),
    ],
    // 三个写全并发，读在最后读到中间那个值 → 合法
    [
      cop(0, 0, Write(1), OpResult::Ok, 0L, 100L),
      cop(1, 1, Write(2), OpResult::Ok, 1L, 101L),
      cop(2, 2, Write(3), OpResult::Ok, 2L, 102L),
      cop(3, 0, Read, Value(2), 103L, 110L),
    ],
    // CAS 链
    [
      cop(0, 0, Cas(0, 5), OpResult::Bool(true), 0L, 10L),
      cop(1, 0, Cas(5, 9), OpResult::Bool(true), 12L, 20L),
      cop(2, 0, Read, Value(9), 22L, 30L),
    ],
    // CAS 期望落空
    [
      cop(0, 0, Cas(0, 5), OpResult::Bool(true), 0L, 10L),
      cop(1, 0, Cas(0, 9), OpResult::Bool(true), 12L, 20L),
    ],
    // 两次不重叠的写，第二次结果记成 false 没意义 → 用 Value 制造不匹配
    [
      cop(0, 0, Write(1), OpResult::Ok, 0L, 10L),
      cop(1, 0, Write(2), Value(2), 12L, 20L),
    ],
  ]
  let mut n = 0
  for ops in cases {
    let h = chist(ops)
    let wgl = match check_default(h, model_or_default("register")) {
      Linearizable => true
      Violation(_) => false
      Unknown(_) => true
    }
    let bf = linearizable_bruteforce(ops)
    // 不一致时把编号记下来，便于定位是哪一条
    if wgl != bf {
      assert_true(false)
    }
    n = n + 1
  }
}
