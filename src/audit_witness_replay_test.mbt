// ============================================================================
// 证据链可重放性（API.md §3 / PLAN.md §6 / README「证据链完整性是硬约束」）
//
// 文档承诺：「`Violation.ops` 是判断所需的最小证据 —— `check(ops)` 必然再次
// 报告违规」。这条承诺是整个工具可用性的前提：`minimize` 直接以它为种子，
// CLI 的「再验证：仍违规 ✓」也直接以它为依据。
//
// 既有覆盖只在两处：`audit_remaining_edges_wbtest.mbt` 的两份手工历史（四档
// 缓存），以及 `checker_test.mbt` 的「见证至少一条操作」。都不是随机扫描。
//
// 本文件把它锁成**可达断言**：四模型 × 多 seed 的随机小历史上，只要
// `check` 报 `Violation`，把 `v.ops` 单独拿出来再查一次就必须还是 `Violation`，
// 并且见证规模/深度都在定义域内。反向验证：把 `build_violation` 的失败点
// 记录关掉（只留前缀），或把子集改成整份历史，这里立刻变红。
// ============================================================================

///|
/// 随机小历史的操作种类池（每个模型只放它认得的 kind）。
fn wr_kinds(model : AnyModel) -> Array[OpKind] {
  match model {
    Register(_) =>
      [
        Write(0),
        Write(1),
        Write(2),
        Write(3),
        Read,
        Cas(0, 1),
        Cas(1, 2),
        Cas(2, 3),
      ]
    Counter(_) => [Write(0), Write(1), Write(2), Write(3), Read]
    Set(_) =>
      [Write(0), Write(1), Write(2), Write(3), Append(0), Append(1), Pop, Read]
    Queue(_) => [Append(0), Append(1), Append(2), Append(3), Pop, Read]
  }
}

///|
/// 形状错乱的结果池：故意混入 write 记 `Value`、read 记 `Ok` 这类组合，
/// 才能真的造出「返回值不匹配」与「模型拒绝转换」两类失败。
fn wr_results() -> Array[OpResult] {
  [Ok, Value(0), Value(1), Value(2), Value(3), Bool(true), Bool(false), Empty]
}

///|
test "证据链：check 给出的见证子集重放必须仍违规（四模型 × 随机历史）" {
  let models = ["register", "counter", "set", "queue"]
  let cfg = CheckConfig::{
    time_budget_ms: 4000,
    max_states: 200_000,
    allow_unknown_results: false,
  }
  let mut violations = 0
  let mut single_op = 0
  let mut bad = 0
  for mname in models {
    let model = model_or_default(mname)
    let kinds = wr_kinds(model)
    let results = wr_results()
    let mut seed = 1
    while seed <= 500 {
      let rng = Rng::new(seed * 13 + 5)
      let n = 1 + rng.below(6)
      let h = History::new()
      let mut i = 0
      while i < n {
        let start = rng.below(30).to_int64()
        let end = start + rng.below(7).to_int64()
        h.add(Operation::{
          id: i,
          process: rng.below(3),
          kind: kinds[rng.below(kinds.length())],
          result: results[rng.below(results.length())],
          start,
          end,
        })
        i = i + 1
      }
      match check_with(h, model, cfg) {
        Violation(v) => {
          violations = violations + 1
          if v.ops.length() == 1 {
            single_op = single_op + 1
          }
          // 见证必须来自这份历史，且不超过它的规模
          if v.ops.length() > h.length() {
            bad = bad + 1
            println("WITNESS-TOO-BIG model=\{mname} seed=\{seed}")
          }
          // depth 是「最长一致前缀」，不可能超过见证条数减一
          if v.depth > v.ops.length() - 1 {
            bad = bad + 1
            println("DEPTH-OUT-OF-BOUNDS model=\{mname} seed=\{seed}")
          }
          match check_with(ops_to_history(v.ops), model, cfg) {
            Violation(_) => ()
            Linearizable => {
              bad = bad + 1
              println("REPLAY-BROKEN model=\{mname} seed=\{seed}")
              println(h.to_jsonl())
            }
            Unknown(reason) => {
              bad = bad + 1
              println("REPLAY-UNKNOWN model=\{mname} seed=\{seed} \{reason}")
            }
          }
        }
        _ => ()
      }
      seed = seed + 1
    }
  }
  // 非空断言：探针必须真的走到违规分支，否则这整段是恒真
  assert_true(violations > 200)
  // 单操作见证（= 历史数据自相矛盾）也要真的出现过，否则
  // `violation_reason` 的 data-inconsistency 分支没被覆盖
  assert_true(single_op > 0)
  assert_eq(bad, 0)
}
