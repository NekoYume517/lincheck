// ============================================================================
// LC-46 —— `minimize` 的规模失控：801 操作历史 157–249 秒（check 只要 0.05 秒）
//
// ## 现象（CLI 实测，native release 构建）
//
//   $ lincheck gen --model register --processes 4 --ops 200 --seed 7 --inject > h.jsonl
//   $ lincheck check     --history h.jsonl --model register   # 0.050 s
//   $ lincheck visualize --history h.jsonl                    # 0.096 s
//   $ lincheck minimize  --history h.jsonl --model register   # 249 s（HEAD）/ 157 s（本轮修后）
//
//   9601 操作历史上：check 2.3 s、visualize 3.1 s、minimize 跑满 **52 分钟**被手工
//   终止（3119448 ms，rc=-1）。CI 上等价于挂死。
//
//   曲线（HEAD）：201 操作 1.2 s / 401 操作 1.4 s / 801 操作 187 s。
//   最后一段是断崖 —— check 在同一批历史上是 0.06 / 0.06 / 0.07 s。
//
// ## 根因
//
// `witness_ok` = 够大 + 仍违规 + 可解释。`explainable_trace` 对子集里每个操作
// 先 `illegal_status`（1 次 `probe_ops`），对「孤立非法」的再对每个同伴跑
// `pair_status`（又 1 次 `probe_ops`）。`probe_ops` 是一次**完整 check**。
// ddmin 的每个候选都要走一遍 `witness_ok`，于是「接受一个候选」成本 O(k²)
// 次 check、kk 轮 O(k) 候选 → O(k³)。
//
// 实测（instrumented）：508 操作的种子（`check` 的见证，恰好等于
// `WITNESS_MAX_ENTRIES`）上，单次 `explainable(508)` = 18 ms，而它被调用了
// 上千次 —— 这就是 187 s 的来源。种子为什么是 508 而不是常见的 2–3：
// 这份 history 的首个 `check` 见证被 `WITNESS_MAX_ENTRIES` 截断到 508。
//
// ## 本轮的修（`fix(checker)` 那一笔）
//
// 1. `explainable_trace` 改成两趟：先 O(k) 收集「孤立非法」，没有就短路
//    返回 true（最常见路径），有才为它们找同伴。语义不变，砍掉「对没病的
//    操作也扫遍同伴」这段纯浪费。
// 2. `ddmin_bounded_trace` 加判定次数硬上限 `DDMin_MAX_PROBES`，并用
//    `chunk` 不重置的写法把轮数从 O(k) 降到 O(log k)。
//
// 实测收益：187 s → 157 s（801 操作），1.4 s → 1.1 s（401 操作）。
//
// ## 但**没有修好** —— 这就是本测例要继续盯着的东西
//
// 157 s 仍然是 check 的 3000 倍。第 3 步「以整份历史为起点 ddmin」在
// k=801 时按 `lc46_cost.py` 的算术是 ~5.6e9 次 probe，`DDMin_MAX_PROBES`
// 只限制了**每趟** ddmin 的次数，而 `minimal_witness_trace` 一次要跑两趟
// （种子 + 整份历史），每趟上限都是 4000 次「含 O(k²) 守卫」的探针。
// 根上仍是「守卫太贵 + 种子太大」，需要换策略（例如先无守卫缩到极小再
// 从那里向上找可解释的补全）—— 那是下一轮的设计问题，不是这里的调参。
//
// 所以本测例**故意保持红色**：它是一条已登记的真实缺陷的回归锁。
// 判据写成「不得比 check 慢 100 倍以上」，修好那天它会自己转绿。
// 若将来有人想让它变绿，只有两条路：真的把 minimize 压下来，
// 或者把这条判据显式改掉（并说明为什么 3000 倍可以接受）。
// ============================================================================

///|
/// 4 进程 × `ops_per_process` × seed 7：与 CLI 复现完全同源。
fn lc46_history(ops_per_process : Int32) -> History {
  let cfg = GenConfig::{
    processes: 4,
    ops_per_process,
    seed: 7,
    concurrency: 1.0,
  }
  inject_violation(
    generate_consistent(register_model(), cfg),
    Register(register_model()),
    7,
  )
}

///|
fn lc46_config() -> CheckConfig {
  CheckConfig::{
    time_budget_ms: 5000,
    max_states: 200000,
    allow_unknown_results: false,
  }
}

///|
test "LC-46: 801 条历史的 minimize 必须与 check 同量级（当前 RED：已登记缺陷）" {
  let h = lc46_history(200)
  assert_true(h.length() > 700)
  let m = register_model()
  let cfg = lc46_config()
  let t0 = @env.now()
  let outcome = check_with(h, m, cfg)
  let check_ms = @env.now() - t0
  match outcome {
    Violation(v) => {
      println(
        "LC-46: check 见证 = \{v.ops.length()} 个操作（历史 \{h.length()} 条），check = \{check_ms} ms",
      )
      // 入口条件：见证规模就是 ddmin 的起始 k。它一旦回到 2–3，本测例要
      // 监视的现象就不在了 —— 把前提显式化，别让它悄悄变成空转。
      assert_true(v.ops.length() >= 100)
    }
    _ => {
      println("LC-46: 期望 Violation")
      assert_true(false)
    }
  }
  let t1 = @env.now()
  let v = minimize_with(h, m, cfg)
  let min_ms = @env.now() - t1
  println(
    "LC-46: minimize = \{min_ms} ms（check 的 \{min_ms / check_ms} 倍）",
  )
  // 修前的实测是 3557 倍（249 s / 0.069 s），本轮修后 ~3000 倍。
  // 这里要求压到 100 倍以内 —— 修好之前它就是红的。
  assert_true(min_ms / check_ms < 100)
  // 结果仍必须自洽：要么给出合格见证，要么如实 NoWitness，不许退化解。
  assert_true(v.ops.length() == 0 || v.ops.length() >= MIN_WITNESS)
}

///|
test "LC-46 反向：小历史必须仍拿到「够大 + 仍违规 + 可解释」的见证" {
  // 这条守的是「为了提速把守卫删掉」这类错误修法。本轮真踩过：
  // 一度加了「起点不可解释就跳过 ddmin」的前置剪枝，结果把 200 条历史
  // 本可拿到的 3 操作见证变成 NoWitness —— 正是这条用例把它抓回来的。
  // 教训：可解释性**不是单调**的，从不可解释的起点出发 ddmin 删掉几条
  // 之后，剩下的子集可能重新可解释。
  let h = lc46_history(50)
  assert_true(h.length() > 100)
  let m = register_model()
  let cfg = lc46_config()
  assert_true(check_with(h, m, cfg) is Violation(_))
  let v = minimize_with(h, m, cfg)
  assert_true(v.ops.length() >= MIN_WITNESS)
  assert_true(v.ops.length() < h.length())
  assert_true(probe_ops(v.ops, m, cfg) is Violation(_))
  assert_true(explainable(v.ops, m, cfg, Expl::new()))
}

///|
test "LC-46 反向：不可解释的起点上 ddmin 仍能收敛出可解释见证（非单调性锁）" {
  // 把「可解释性不单调」这个引理钉成持续监视：起点 `pool` 不可解释，
  // 但从它出发的 ddmin 必须还能给出一个合格见证。
  // 任何「起点必须先可解释」的前置剪枝都会让这条红。
  let h = lc46_history(50)
  let m = register_model()
  let cfg = lc46_config()
  let pool = h.operations
  // 前提一：pool 自己不可解释
  if explainable(pool, m, cfg, Expl::new()) {
    println(
      "LC-46: 本用例要求 pool 不可解释，但它可解释 —— 前提失效，请换历史",
    )
    assert_true(false)
  }
  // 前提二：pool 确实违规
  assert_true(probe_ops(pool, m, cfg) is Violation(_))
  // 结论：从 pool 出发的 ddmin 必须拿到合格见证
  let found = ddmin_bounded(pool, m, cfg, 200, MIN_WITNESS, Some(Expl::new()))
  assert_true(probe_ops(found, m, cfg) is Violation(_))
  assert_true(explainable(found, m, cfg, Expl::new()))
  assert_true(found.length() >= MIN_WITNESS)
}
