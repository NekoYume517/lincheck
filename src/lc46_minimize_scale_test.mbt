// ============================================================================
// LC-46 —— `minimize` 的规模失控：801 操作历史 25–250 秒（check 只要 0.05 秒）
//
// ## 现象（CLI 实测，native release 构建）
//
//   $ lincheck gen --model register --processes 4 --ops 200 --seed 7 --inject > h.jsonl
//   $ lincheck check     --history h.jsonl --model register   # 0.050 s
//   $ lincheck visualize --history h.jsonl                    # 0.096 s
//   $ lincheck minimize  --history h.jsonl --model register   # 187 s（HEAD）
//
//   9601 操作历史上：check 2.3 s、visualize 3.1 s、minimize 跑满 **52 分钟**被手工
//   终止（3119448 ms，rc=-1）。CI 上等价于挂死。
//
// ## 根因
//
// `witness_ok` = 够大 + 仍违规 + 可解释。`explainable_trace` 对子集里每个操作
// 先 `illegal_status`（1 次 `probe_ops`），旧写法对「孤立非法」的**立刻**再对
// 每个同伴跑 `pair_status`（又 1 次 `probe_ops`）。`probe_ops` 是一次**完整
// check**。ddmin 的每个候选都要走一遍 `witness_ok` → O(k³)。
//
// 触发点：这份历史的 `check` 见证被 `WITNESS_MAX_ENTRIES` 截断到 **508**，
// 于是 ddmin 的起始 k 从通常的 2–3 变成 508。
//
// ## 本轮的修（`fix(checker)` 那一笔）
//
// 1. `explainable_trace` 改两趟：先 O(k) 收集「孤立非法」，为空就短路返回
//    true（最常见路径）；非空才为它们逐个找同伴。语义完全不变。
// 2. `ddmin_bounded_trace` 加判定次数硬上限 `DDMin_MAX_PROBES`，并把
//    「接受候选后 chunk 归零重开」改成「留在同一 chunk 继续扫」。
//
// ## 判据为什么**不测时间**（本轮裁决，写给下一轮）
//
// 第一版这条用例写的是 `minimize 耗时 / check 耗时 < 100`。那是**环境因变量**：
// 同一工具链、同一条命令、同一份历史，Lead 机器实测比值在 **469 / 647 / 751**
// 之间跳，开发机是 ~3000。差多少全看 CPU 快慢和有没有别的活在跑。
//
// 拿秒数当契约有两个后果：修好的那天可能因为换了机器**还红着**；而且"红锁"
// 一旦长期挂在仓库里，全绿这条底线就形同废止 —— 于是没人再看它。
// **性能锁不能拿秒数当契约。**
//
// 改成 O(k³) 的**直接等价物**：`minimize` 内部的可解释性判定次数。
//
// 三个计数器（`minimize.mbt` 的 `explain_probe_counts` / `ddmin_candidate_count`，
// 与 `checker.mbt` 的 `cache_key_calls` 同一约定：生产路径上只是一次自增）：
//
// - `illegal_probes`：`illegal_status` 缓存未命中、真跑了一次 `probe_ops`；
// - `pair_probes`：`pair_status` 缓存未命中、真跑了一次 `probe_ops`（**主犯**）；
// - `ddmin_candidates`：ddmin 试过的候选数。
//
// 它们是确定性的整数：同一历史在任何机器上都得同一个值。
//
// ## 阈值怎么来的（源码可算，不是拍的）
//
// 修后的两趟筛选把 `pair_probes` 的上界压到「孤立非法的操作数 × k」：
// 每个孤立非法的操作最多试 k-1 个同伴（命中一个就停）。这条历史实测
// `illegal_probes = 508`、`pair_probes = 4364` —— 4364 < 508 × 508 = 258064
// 的一个小零头，因为绝大多数操作并不孤立非法（第一趟就短路了）。
//
// 判据取 **`pair_probes <= k * k / 4`**（k=508 时 = 64516）：
//   - 修后实测 4364，距离阈值 15 倍余量；
//   - mutation（退回旧的一趟内联写法）实测 **78057**，**越过阈值** —— 断言红。
//
// 这条阈值与机器无关，只与「守卫是不是又退回到对每个操作扫遍每个同伴」有关。
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
test "LC-46: 801 条历史的可解释性判定次数必须低于 k²/4（不测时间）" {
  let h = lc46_history(200)
  assert_true(h.length() > 700)
  let m = register_model()
  let cfg = lc46_config()
  let mut k = -1
  if check_with(h, m, cfg) is Violation(v) {
    k = v.ops.length()
  }
  // 入口条件：见证规模就是 ddmin 的起始 k。它一旦回到 2–3，本测例要监视的
  // 现象就不在了 —— 把前提显式化，别让它悄悄变成空转。
  println("LC-46: check 见证 k = \{k}（历史 \{h.length()} 条）")
  assert_true(k >= 100)

  reset_minimize_counters()
  let v = minimize_with(h, m, cfg)
  let (illegal, pair) = explain_probe_counts()
  let cands = ddmin_candidate_count()
  println(
    "LC-46: illegal_probes=\{illegal} pair_probes=\{pair} ddmin_candidates=\{cands}（k²=\{k * k}）",
  )

  // 判据一：pair_status 的未命中次数不得超过 k²/4。
  // 修后 4364；旧写法（mutation）78057；阈值 64516。
  let bound = k * k / 4
  if pair > bound {
    println(
      "LC-46: pair_probes \{pair} 超过 k²/4 = \{bound} —— 可解释性守卫退回到「每个操作扫遍每个同伴」",
    )
    assert_true(false)
  }
  // 判据二：ddmin 候选数也不得超过探针预算的份额。
  // 4000 = `minimize.mbt` 的 `DDMin_MAX_PROBES`（私有常量），一次 minimize
  // 最多跑两趟 ddmin（种子 + 整份历史），故上界取 2×。
  assert_true(cands <= 8000)
  // 判据三：结果仍必须自洽 —— 要么给出合格见证，要么如实 NoWitness，
  // 绝不许为了快而输出退化解。
  assert_true(v.ops.length() == 0 || v.ops.length() >= MIN_WITNESS)
}

///|
test "LC-46 反向：小历史必须仍拿到「够大 + 仍违规 + 可解释」的见证" {
  // 这条守的是「为了提速把守卫删掉」这类错误修法。本轮真踩过：
  // 一度加了「起点不可解释就跳过 ddmin」的前置剪枝，结果把 200 条历史
  // 本可拿到的 3 操作见证变成 NoWitness —— 正是这条用例把它抓回来的。
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
  if explainable(pool, m, cfg, Expl::new()) {
    println(
      "LC-46: 本用例要求 pool 不可解释，但它可解释 —— 前提失效",
    )
    assert_true(false)
  }
  assert_true(probe_ops(pool, m, cfg) is Violation(_))
  let found = ddmin_bounded(pool, m, cfg, 200, MIN_WITNESS, Some(Expl::new()))
  assert_true(probe_ops(found, m, cfg) is Violation(_))
  assert_true(explainable(found, m, cfg, Expl::new()))
  assert_true(found.length() >= MIN_WITNESS)
}
