// cli_selfcheck_verdict_test.mbt — `selfcheck` 退出码的三态决策表
//
// 锁定的缺陷（2026-11-21 审计 LC-25）：
//
// 旧判据是 `violations == 0 && unknowns == 0 && injected_missed == 0 &&
// injected == total` 才 PASS(0)，否则一律 `结果：FAIL` + `EXIT_VIOLATION`(1)。
// 摘要里「结论未知」明明单独成行，退出码却与「误判违规 / 漏检注入」同为 1 ——
// `docs/exit-codes.md` 把 1 定义为**有效结论**（"this history really is not
// linearizable"），把 3 定义为**没有结论**，并专门写明「3 不能被四舍五入到
// 任何邻居」。CI 拿 1 无法区分「检查器判错了」和「这台机器上没跑完」。
//
// 为什么不是 CLI 级红：`selfcheck` 不接受 `--budget-ms`（白名单里没有，内部
// 用 `CheckConfig::default()` 的 5000 ms），唯一能造出 Unknown 的路径是生成
// 一份 > 5 s 才搜完的病态历史 —— 那会把机器速度写进断言（LC-13 的教训）。
// 所以按仓库既有做法把判据抽成纯函数，决策表逐格锁死；反向验证见证据日志
// `evidence/04-selfcheck-verdict-REVERSE.log`（把 unknowns 分支改回 1 → 变红）。

///|
test "LC-25: selfcheck 全绿才 PASS（0）" {
  assert_eq(selfcheck_verdict(0, 0, 0, 3, 3), EXIT_OK)
}

///|
test "LC-25: 只有「结论未知」时必须报 3，不得折成 1" {
  // 合法历史全过、注入全检出，但有 1 个 seed 预算耗尽。
  assert_eq(selfcheck_verdict(0, 1, 0, 3, 3), EXIT_UNKNOWN)
  // 全部 seed 都没跑出结论也是 3，不是 1。
  assert_eq(selfcheck_verdict(0, 3, 0, 3, 3), EXIT_UNKNOWN)
}

///|
test "LC-25: 检查器真出错时是 1（未知不得盖住确定性错误）" {
  // 误判违规 + 未知同时出现：确定性错误优先。
  assert_eq(selfcheck_verdict(1, 1, 0, 3, 3), EXIT_VIOLATION)
  // 漏检注入的违规。
  assert_eq(selfcheck_verdict(0, 0, 1, 3, 3), EXIT_VIOLATION)
  // 注入档没跑满（模板被吸收 / 一条都没注入）不是通过。
  assert_eq(selfcheck_verdict(0, 0, 0, 2, 3), EXIT_VIOLATION)
  assert_eq(selfcheck_verdict(0, 0, 0, 0, 3), EXIT_VIOLATION)
}

///|
test "LC-25: 未知 + 注入档没跑满：确定性错误优先（1）" {
  assert_eq(selfcheck_verdict(0, 2, 0, 2, 3), EXIT_VIOLATION)
}
