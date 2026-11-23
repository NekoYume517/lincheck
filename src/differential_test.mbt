// ============================================================================
// differential_test.mbt — 差分回归：检查器结论 vs 暴力枚举
//
// 性质：对小规模历史（≤ 7 个操作），WGL 搜索的结论必须与「枚举所有尊重
// happens-before 的全序、逐个喂给模型」的暴力判定完全一致：
//   · 暴力找到合法全序  ⇔  check 判 Linearizable
//   · 暴力找不到        ⇔  check 判 Violation
// 任何一例不一致都是搜索/剪枝/缓存的真 bug（历史生成用 generate_random 的
// 随机结果值，覆盖合法与非法两种历史，比 selfcheck 只测合法历史更狠）。
// ============================================================================

///|
/// 枚举所有尊重 happens-before 的全序；存在一条模型全接受的就返回 true。
fn brute_force_linearizable(ops : Array[Operation], model : AnyModel) -> Bool {
  let n = ops.length()
  let used : Array[Bool] = []
  for _ in ops {
    used.push(false)
  }
  let order : Array[Operation] = []
  fn go(depth : Int32) -> Bool {
    if depth == n {
      // 逐个应用到模型，结果必须与历史一致
      let mut state = model.init()
      for op in order {
        match model.apply(state, op.kind) {
          Some((next, expected)) => {
            // 结果判据必须走 Model::accepts（A1，2026-11-23）：
            // API.md §2 规定 set 模型 Read 可返回任一当前成员，
            // `apply` 给出的最小成员只是生成器用的合法代表结果。
            // 旧实现在这里做严格相等，把 set 偷换成「Read 恒返回
            // 最小成员」的另一个对象，与 check 的结论系统性背离。
            // 严格相等是默认 accepts 的语义；有自定义 accepts 的模型
            // （set）必须走同一钩子，两个判定器才算在测同一个契约。
            let ok = model.accepts(state, op.kind, expected, op.result)
            if !ok {
              return false
            }
            state = next
          }
          None => return false
        }
      }
      return true
    }
    for i in 0..<n {
      if used[i] {
        continue
      }
      // 尊重 happens-before：任何尚未排入的操作 b，若某已排入的 a 满足
      // happens_before(b, a)，则 b 必须已在前面——这里只需检查「本次要排
      // 的 op 没有被迫排在任何剩余操作之后」：即不存在剩余操作 b 使
      // happens_before(op, b)……更直接的判据：op 排在当前位置，当且仅当
      // 没有未用的 b 满足 happens_before(op_i, b) 为假并且 happens_before(b, op_i)
      // 也不必——正确条件：所有满足 happens_before(b, op_i) 的 b 都已用掉。
      let mut ready = true
      for j in 0..<n {
        if !used[j] && j != i && happens_before(ops[j], ops[i]) {
          ready = false
        }
      }
      if !ready {
        continue
      }
      used[i] = true
      order.push(ops[i])
      if go(depth + 1) {
        return true
      }
      order.pop() |> ignore
      used[i] = false
    }
    false
  }

  go(0)
}

///|
/// 对随机历史做差分：check 与暴力必须一致。
fn differential_once(model : AnyModel, seed : Int32) -> Bool {
  let cfg = GenConfig::{
    processes: 2,
    ops_per_process: 3,
    seed,
    concurrency: (seed % 11).to_double() / 10.0,
  }
  let h = generate_random(model, cfg)
  let n = h.length()
  if n == 0 || n > 7 {
    return true // 超出暴力能力，跳过
  }
  // 严格模式：无 Nil（generate_random 不会产 Nil），预算给足
  let check_cfg = CheckConfig::{
    time_budget_ms: 60000,
    max_states: 200000,
    allow_unknown_results: false,
  }
  let verdict = match check(h, model, check_cfg) {
    Linearizable => true
    Violation(_) => false
    Unknown(_) =>
      // 60s 预算下 7 个操作不可能超时；出现即失败
      false
  }
  let brute = brute_force_linearizable(h.operations, model)
  if verdict != brute {
    println("DIFF MISMATCH model=\{model.name()} seed=\{seed}")
    println(h.to_jsonl())
    println("check=\{verdict} brute=\{brute}")
    return false
  }
  true
}

///|
test "differential: check vs brute force (random histories, all models)" {
  let models = [
    AnyModel::Register(register_model()),
    AnyModel::Counter(counter_model()),
    AnyModel::Set(set_model()),
    AnyModel::Queue(queue_model()),
  ]
  for m in models {
    for seed in 1..<=120 {
      assert_true(differential_once(m, seed))
    }
  }
}

///|
/// 合法历史（generate_consistent）必须判 Linearizable——扩 seeds 覆盖。
test "differential: consistent histories stay linearizable" {
  let models = [
    (AnyModel::Register(register_model()), "register"),
    (AnyModel::Counter(counter_model()), "counter"),
    (AnyModel::Set(set_model()), "set"),
    (AnyModel::Queue(queue_model()), "queue"),
  ]
  for (m, name) in models {
    for seed in 1..<=200 {
      let cfg = GenConfig::{
        processes: 1 + seed % 4,
        ops_per_process: 1 + seed % 5,
        seed,
        concurrency: (seed % 11).to_double() / 10.0,
      }
      let h = generate_consistent(m, cfg)
      let check_cfg = CheckConfig::{
        time_budget_ms: 60000,
        max_states: 200000,
        allow_unknown_results: false,
      }
      match check(h, m, check_cfg) {
        Linearizable => ()
        other => {
          println("CONSISTENT MISJUDGED model=\{name} seed=\{seed}")
          println(h.to_jsonl())
          let verdict_text = match other {
            Linearizable => "linearizable"
            Violation(_) => "violation"
            Unknown(r) => "unknown(\{r})"
          }
          assert_true(false, msg="\{verdict_text}")
        }
      }
    }
  }
}

///|
/// A1（2026-11-23）：暴力基准的结果判据必须走 `Model::accepts`。
///
/// API.md §2：set 模型 Read「可返回任一当前成员 Value(v)」，`apply` 给出的
/// 最小成员只是生成器用的合法代表结果，`accepts` 才是结果校验的权威钩子。
/// 旧基准用「与 apply 代表值严格相等」判结果，等于把 set 偷换成
/// 「Read 恒返回最小成员」的另一个对象 —— Append(1)、Append(2) 并发写后
/// 读到非最小的 2 会被误判违规，而 check 正确判线性一致
/// （探针 evidence/A1-diff-scratch.log：check=true brute=false）。
test "differential-a1: brute force must validate results via accepts" {
  let m = AnyModel::Set(set_model())
  let ops = [
    Operation::{
      id: 0,
      process: 0,
      kind: Append(1),
      result: Ok,
      start: 0L,
      end: 10L,
    },
    Operation::{
      id: 1,
      process: 1,
      kind: Append(2),
      result: Ok,
      start: 0L,
      end: 10L,
    },
    Operation::{
      id: 2,
      process: 0,
      kind: Read,
      result: Value(2),
      start: 20L,
      end: 30L,
    },
  ]
  let h = History::{ operations: ops, }
  let cfg = CheckConfig::{
    time_budget_ms: 60000,
    max_states: 200000,
    allow_unknown_results: false,
  }
  let verdict = match check(h, m, cfg) {
    Linearizable => true
    Violation(_) => false
    Unknown(_) => false
  }
  assert_true(
    verdict,
    msg="check 必须接受读到任一集合成员（API.md §2 set 契约）",
  )
  let brute = brute_force_linearizable(ops, m)
  assert_true(
    brute,
    msg="暴力基准必须与 Model::accepts 契约一致，接受 Value(2)",
  )
}
