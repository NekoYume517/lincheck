// 2026-11-12 后续（lincheck）预算轮询粒度回归：
//
// 缺陷形态（`audit/2026-11-12/lincheck/REPORT.md` 未修第 1 条）：
// `poll_deadline` 只在 `explored % 256 == 0` 看时钟，于是**任何**预算的
// 第一次截止检查都发生在第 256 个节点。实测 24000 操作历史、`--budget-ms 1`
// 时搜索段耗 135 ms（预算的 135 倍），`--budget-ms 50` 时耗 128 ms；
// 用户给的预算实际上只在「256 个节点」这个粒度上生效。
//
// 危害不是「慢」而是「按你给的预算跑」这条承诺不成立：`--budget-ms 1` 与
// `--budget-ms 50` 在同一份大历史上给出完全相同的进度（都是 256 个节点），
// 两个不同预算在可观测输出上不可区分。

///|
/// 小预算必须在**前几个节点**就被打断，而不是等到第 256 个。
///
/// 判据用 `CheckStats::explored`（可观测的搜索进度），**不用真实耗时**：
/// 耗时随机器浮动，节点数不会。6000 操作历史里单个搜索节点是 O(n) 的
/// （缓存键要拼 6000 位剩余位串、候选表要全扫），实测约 0.1 ms/节点，
/// 因此 1 ms 预算在 256 节点这一档之前必然早就耗尽——修复前稳定停在
/// 256（28 ms，预算的 28 倍），修复后停在个位数节点。
test "budget: 1ms budget stops within the first nodes, not at the 256th" {
  let h = generate_consistent(register_model(), GenConfig::new(4, 1500, 7, 0.5))
  inspect(h.length(), content="6000")
  let tight = CheckConfig::{
    time_budget_ms: 1,
    max_states: 200_000,
    allow_unknown_results: false,
  }
  let (outcome, stats) = check_with_stats(
    h,
    AnyModel::Register(register_model()),
    tight,
  )
  // 结论方向不变：被截断的搜索只许报 Unknown
  match outcome {
    Unknown(_) => ()
    Linearizable => abort("1ms budget finished a 6000-op history")
    Violation(_) => abort("legal history reported as a violation")
  }
  assert_true(stats.timed_out)
  // 回归目标：首个截止检查点不得等到第 256 个节点（旧实现的第一档）。
  //
  // 这条上界的**方向与负载同向**——机器越慢/越忙，explored 只会更小，
  // 所以它在任何负载下都成立，属于契约（「小预算不该拖到第 256 个节点」），
  // 不是「这台机器的速度」。
  assert_true(stats.explored < 256)
  // 2026-11-17 审计 LC-13：这里原本还有一条 `explored <= 64`
  //（「实测 10 个节点左右，留 6 倍余量」）。它把**机器变快**写成了失败条件：
  // 比本机快 6 倍以上的机器上，1 ms 足以探索超过 64 个节点，用例红而实现是对的。
  // 「轮询三档」的确定性契约改由 `audit_poll_due_wbtest.mbt` 直接锁 `poll_due`
  //（纯函数、不看时钟、与机器无关），这里只保留方向安全的规模上界。
}
