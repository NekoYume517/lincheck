// ============================================================================
// LC-7 不变量：n >= 1 的合法历史必然可注入违规
//
// `selfcheck` 的结论行同时声称两件事：合法历史不被误判（无假阳性），
// 以及注入的违规总能被检出（对已知坏样本有灵敏度）。第二件事成立的前提是
// `inject_violation` 真的改出了违规；一旦它原样返回，selfcheck 会打印
// 「注入违规被发现：0 / 0」却仍然是 PASS —— 无证据通过。
//
// 可达性结论（2026-11-17 审计 LC-7）：**n == 0 是唯一能让注入全部落空的输入**，
// 而它已被 `selfcheck_scale` 以 exit 2 拒绝。理由是可证明的：
//
//   1. `inject_violation` 逐条改某个操作的 `result`，候选集里除原值外还有 7 个
//      （`Ok` / `Value(0..3)` / `Bool(true)` / `Bool(false)` / `Empty`）；
//   2. 四个内建模型对 `Write`/`Append` 只接受 `Ok`、对 `Cas`/`Pop` 只接受
//      `Bool(...)`、对 `Read` 只接受 `Value(...)`；凡**形状不同**的候选结果，
//      在任何状态下都会被 `Model::accepts` 拒 —— 那条操作无法被线性化；
//   3. 于是「换错形状」的候选必然把历史变成 Violation。唯一可能被吸收的是
//      `set` 的 `Read` 改成 `Value(0..3)`（成员存在即合法），但同一批候选里的
//      `Ok`/`Bool`/`Empty` 仍然必违规，注入照样成功。
//
// 所以本用例锁的是「注入可用」这条前提本身，而不是某个具体缺陷形态：
// 它把 DEMO 的「300 / 300 全检出」从「顺带成立」变成有断言。反向验证方式：
// 把 `inject_violation` 改成原样返回 history，本用例立刻变红。
// ============================================================================

///|
/// 覆盖「极小到中等」的规模：n == 1 是最容易被空历史/空注入掩盖的一档，
/// 也是 `processes × ops` 两个维度都取 1 的退化边界。
fn inject_invariant_configs() -> Array[GenConfig] {
  [
    GenConfig::new(1, 1, 1, 0.0),
    GenConfig::new(1, 1, 2, 1.0),
    GenConfig::new(1, 2, 3, 0.5),
    GenConfig::new(2, 3, 7, 0.5),
    GenConfig::new(3, 4, 42, 0.5),
    GenConfig::new(4, 6, 99, 0.3),
  ]
}

///|
test "LC-7 不变量：n >= 1 的合法历史必可注入违规（4 模型 × 6 规模）" {
  for name in ["register", "counter", "set", "queue"] {
    let model = model_or_default(name)
    for cfg in inject_invariant_configs() {
      let h = generate_consistent(model, cfg)
      // 前提一：生成器不得静默缩短（total = processes × ops 是公开契约）。
      inspect(
        h.length(),
        content=(cfg.processes * cfg.ops_per_process).to_string(),
      )
      // 前提二：这份历史确实线性一致（否则「注入」测的就不是灵敏度）。
      inspect(
        outcome_str(check(h, model, CheckConfig::default())),
        content="Linearizable",
      )
      // 核心不变量：n >= 1 ⇒ 注入必然改出东西。
      let bad = inject_violation(h, model, cfg.seed)
      inspect(bad.to_jsonl() == h.to_jsonl(), content="false")
      // 且改出来的那份必须被判为违规（注入自己也要被独立复检）。
      inspect(
        outcome_str(check(bad, model, CheckConfig::default())),
        content="Violation",
      )
    }
  }
}
