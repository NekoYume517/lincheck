// ============================================================================
// lc42_fold_no_overclaim_test.mbt —— 命中折叠**不得**把"子树里某一层失败"
// 误当成"整棵子树失败"（LC-42 其二的反例回归锁）
//
// ## 这段历史怎么来的
//
// LC-42 其二的修复是「命中后把归纳结论折回最近已判死的祖先」。第一版实现
// 图省事，把命中直接写成 `return false` —— 等价于「命中的这个节点也算整棵
// 子树失败」。`lc41` 的 `seed = 15`（3 进程 × 2 操作、concurrency 0.8、固定
// LCG）当场从 `Linearizable` 变成 `Violation`，被既有的全排列参考对拍抓住。
//
// 原因是：命中的节点往往**自己还没试完候选**。它的子树里含有缓存中记着的
// 那个失败子问题，但它自己的兄弟分支还没有被排除 —— 直接把它判死，就等于
// 漏掉那些兄弟，于是把"可线性化"的历史误报成违规。
//
// ## 这条测试锁什么
//
// 不只断言 seed=15 的判定，还断言**每个 seed 的 explored 都有界**：折叠一旦
// 退化成「每层重新查一次缓存」，缓存密集的搜索会膨胀到跑不完。两条一起看，
// 才不会出现"判定对了但成本爆了"或"成本对了但判定错了"。
//
// 判据全部是精确计数与布尔值，不依赖机器速度。
// ============================================================================

///|
/// `lc41` 里抓到这个回归的那份历史（3 进程 × 2 操作、seed 15、0.8 并发）。
fn lc42_overclaim_history() -> History {
  generate_random(register_model(), GenConfig::new(3, 2, 15, 0.8))
}

///|
fn lc42_overclaim_cfg() -> CheckConfig {
  { time_budget_ms: 0, max_states: 200_000, allow_unknown_results: false, }
}

///|
/// **判据一**：这份历史必须被判为 `Linearizable`，且与全排列参考一致。
///
/// 把命中节点连坐（第一版）会得到 `Violation`，这条立刻红。
test "LC-42: 命中折叠不得把可线性化的历史误判为违规（lc41 seed=15）" {
  let h = lc42_overclaim_history()
  let expected = lc41_ref_linearizable(h.operations)
  if !expected {
    // 参考实现本身说违规的话，这条锁就失去意义 —— 先钉住前提。
    println(
      "LC-42: 前提失效 —— 参考实现判定 seed=15 并非线性一致",
    )
    assert_true(false)
  }
  let (outcome, _) = check_with_stats(h, register_model(), lc42_overclaim_cfg())
  if !(outcome is Linearizable) {
    println(
      "LC-42: seed=15 被判为违规（命中折叠把命中节点连坐了）",
    )
    assert_true(false)
  }
}

///|
/// **判据二**：同一份历史在**关缓存**时的判定必须相同。
///
/// 关缓存是"没有归纳结论可用"的极端，它给出的答案是最保守的正确值。
/// 折叠如果让开缓存与关缓存分道扬镳，这条会红。
test "LC-42: 开缓存与关缓存对 seed=15 给出同一判定" {
  let h = lc42_overclaim_history()
  let m_off = register_model()
  let (cached, stats_cached) = check_with_stats(h, m_off, lc42_overclaim_cfg())
  let (uncached, _) = check_with_stats(h, m_off, CheckConfig::{
    time_budget_ms: 0,
    max_states: 0,
    allow_unknown_results: false,
  })
  if (cached is Linearizable) != (uncached is Linearizable) {
    println(
      "LC-42: seed=15 开缓存=\{cached is Linearizable} 关缓存=\{uncached is Linearizable}",
    )
    assert_true(false)
  }
  // 前提：这份历史确实用到了缓存（否则这条判据 vacuous）。
  if stats_cached.cache_size == 0 {
    println("LC-42: seed=15 一次缓存条目都没写，判据 vacuous")
    assert_true(false)
  }
}

///|
/// **判据三**：缓存密集史上的 `explored` 必须与 `cache_size` 同阶 ——
/// 折叠一旦退化成"每层重查一次"，比值会从几百倍跳到上万倍。
///
/// 形态：`n` 条全并发同值写 + 一条读到不可能值的读。取 `n = 9`
/// （旧实现 986410 个节点；折叠后 2305；倍数超过 400 即判失败）。
test "LC-42: 缓存密集史上 explored 与 cache_size 同阶（折叠未退化）" {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 9 {
    ops.push({
      id: i,
      process: i % 3,
      kind: Write(5),
      result: Ok,
      start: 0L,
      end: 100L,
    })
    i = i + 1
  }
  ops.push({
    id: 99,
    process: 9,
    kind: Read,
    result: Value(3),
    start: 200L,
    end: 210L,
  })
  let h : History = { operations: ops, }
  let (outcome, stats) = check_with_stats(
    h,
    register_model(),
    lc42_overclaim_cfg(),
  )
  if !(outcome is Violation) {
    println("LC-42: 9 条并发写 + 假读应判违规")
    assert_true(false)
  }
  if stats.cache_size == 0 {
    println("LC-42: 缓存密集史没有条目，判据 vacuous")
    assert_true(false)
  }
  if stats.explored > 400 * stats.cache_size {
    println(
      "LC-42: explored=\{stats.explored} 相对 cache_size=\{stats.cache_size} 膨胀（折叠退化）",
    )
    assert_true(false)
  }
}
