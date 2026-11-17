// ============================================================================
// selfcheck_summary_wbtest.mbt —— `selfcheck` 摘要的口径（LC-17，2026-11-17-b 第二轮）
//
// DISCIPLINE §5-3 的第一族是「结论正确但口径分叉」：数字都对，只有**含义**错。
// `selfcheck` 的摘要曾经就是这一族：
//
// ```text
// $ lincheck selfcheck --model register --seeds 300 --processes 3 --ops 4
// selfcheck  model=register  seeds=300  ops/seed=4          ← 每个 seed 实际是 12 条
// ```
//
// `--ops` 是**每个客户端**的操作数（`API.md` §7、`docs/DEMO.md` §七 都这么写），
// 一个 seed 生成 `processes × ops` 条操作，摘要却把「每客户端操作数」标成
// `ops/seed` —— 读者按它估算工作量会差 `processes` 倍（默认 3 倍）。
// `--processes 0` 被钳制成 1 时更糊涂：头部报的 0 与实际生效的 1 自相矛盾。
//
// 修法：头部把三个量分开写（`clients` 报**生效后**的客户端数、`ops/client`、
// `ops/seed`），计数段统一说明单位是「seed 的个数」。两个格式化函数抽成纯函数，
// 于是 main 包也能在 `*_wbtest.mbt` 里逐字节断言（stdout 拿不到，见
// `json_shape_wbtest.mbt` 的说明）。
// ============================================================================

///|
/// 头部三件事必须分开：客户端数（生效后的）、每客户端操作数、每 seed 操作数。
test "LC-17: selfcheck 头部三个规模量各就各位（ops/seed 曾等于 ops/client）" {
  inspect(
    selfcheck_header("register", 300, 3, 4, 12),
    content="selfcheck  model=register  seeds=300  clients=3  ops/client=4  ops/seed=12",
  )
  // `--processes 0` 钳制为 1：头部必须报**生效后**的客户端数，
  // 否则 `clients=0 / ops/seed=2` 与实际生成的 2 条操作自相矛盾。
  inspect(
    selfcheck_header("queue", 5, 0, 2, 2),
    content="selfcheck  model=queue  seeds=5  clients=1  ops/client=2  ops/seed=2",
  )
  // 单客户端：三个数恰好相等，但仍然必须是三个独立的字段名（口径不能靠巧合）
  inspect(
    selfcheck_header("set", 1, 1, 1, 1),
    content="selfcheck  model=set  seeds=1  clients=1  ops/client=1  ops/seed=1",
  )
}

///|
/// 计数段：五个计数全部是「seed 的个数」，且 `failed` 由两个来源派生。
test "LC-17: selfcheck 计数段的单位一律是 seed 的个数（且分母是 injected）" {
  inspect(
    selfcheck_body(0, 0, 3, 0, 3),
    content="  · 合法历史全部通过：是 ✓\n    - 误判违规：0\n    - 结论未知：0\n  · 注入违规被发现：3 / 3",
  )
  // 误判/未知都算「不通过」，且是第一行唯一的来源
  inspect(
    selfcheck_body(2, 1, 3, 0, 3),
    content="  · 合法历史全部通过：否 ✗\n    - 误判违规：2\n    - 结论未知：1\n  · 注入违规被发现：3 / 3",
  )
  // 「注入违规被发现：a / b」的 b 是**真的做过注入的 seed 数**（injected），
  // 不是 seeds：两者在 n ≥ 1 时相等，但语义不同。注入没做成时补一行诊断
  // （CLI 上当前不可达，这里直接对格式化函数断言，把一个「只能打印」的分支
  // 变成可断言的输出）。
  inspect(
    selfcheck_body(0, 0, 2, 1, 3),
    content="  · 合法历史全部通过：是 ✓\n    - 误判违规：0\n    - 结论未知：0\n  · 注入违规被发现：1 / 2\n    - 未产生注入的 seed：1（注入模板为空，或本配置下所有单点改写都能被模型吸收）",
  )
}
