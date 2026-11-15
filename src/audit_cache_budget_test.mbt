// ============================================================================
// audit_cache_budget_test.mbt — 缓存密集搜索与时间预算的交互
//
// 攻击面（2026-11-15 审计 #5）：Lowe 缓存命中发生在「节点入口记账与时钟
// 轮询之后」（checker.mbt 的 dfs：explored += 1 → poll_deadline → 缓存查询），
// 因此命中节点既计入 explored 也参与超时判定，缓存密集阶段无法绕过预算。
// 这里用两条实测锁住这个前提，而不是只靠读码：
//
// 历史形状：12 条全并发同值写 + 一条读到不可能值的读。全部写互相并发且
// 都匹配，搜索树的失败点在「16... 12 条写全部线性化后剩 {read}」处收敛：
// 任何到达「剩 {read}」的路径共享同一个缓存键（状态 [5] + 剩余位串相同），
// 之后每次抵达都是缓存命中。budget 0 下的访问计数完全由搜索结构决定、
// 与机器速度无关（2026-11-15 实测两次一致）：
//
//   explored   = 12×2^11 + 1 = 24577
//   cache_hits = 10×2^11 + 1 = 20481   （占访问节点的 ~83%）
//   cache_size = 2^12       = 4096
//
// 2026-11-15 审计 #4 附带结论：minimize 对 4 模型 × 40 seeds 的注入历史
// 二次最小化逐字节幂等（160/160 无差异、无更小），幂等性由
// cross_reference_test 的 witness-replay 守护共同覆盖，本文件不重复。
// ============================================================================

///|
test "budget: 缓存密集搜索尊重预算且绝不假接受" {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 12 {
    ops.push(cop(i, i % 3, Write(5), Ok, 0L, 100L))
    i = i + 1
  }
  ops.push(cop(99, 9, Read, Value(3), 200L, 210L))
  let h = chist(ops)
  // 1) budget 0 = 不设上限：必须完成并给出 Violation，且结构计数逐位锁定。
  //    这三条数字同时证明「缓存确实承担了大部分工作」——没有这个前提，
  //    下一条的『缓存密集』只是口头声明。
  let cfg0 : CheckConfig = {
    time_budget_ms: 0,
    max_states: 200_000,
    allow_unknown_results: false,
  }
  let (outcome0, stats0) = check_with_stats(h, register_model(), cfg0)
  inspect(outcome_str(outcome0), content="Violation")
  assert_true(!stats0.timed_out)
  inspect(stats0.explored, content="24577")
  inspect(stats0.cache_hits, content="20481")
  inspect(stats0.cache_size, content="4096")
  // 2) budget 1ms：真违规历史在任何预算下都绝不返回 Linearizable
  //    （返回它 = 假接受 = 漏报）；若超时则 timed_out 必须为真——
  //    时钟在缓存命中为主的阶段同样生效。机器快到 1ms 内搜完时
  //    如实返回 Violation（结论集合 {Unknown, Violation} 与机器无关）。
  let cfg1 : CheckConfig = {
    time_budget_ms: 1,
    max_states: 200_000,
    allow_unknown_results: false,
  }
  let (outcome1, stats1) = check_with_stats(h, register_model(), cfg1)
  match outcome1 {
    Linearizable => assert_true(false)
    Unknown(_) => assert_true(stats1.timed_out)
    Violation(_) => assert_true(!stats1.timed_out)
  }
}
