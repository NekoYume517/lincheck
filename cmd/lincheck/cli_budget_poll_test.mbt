// cli_budget_poll_test.mbt — 预算轮询粒度（2026-11-12 后续 L-1）的退出码侧回归。
//
// `poll_deadline` 修成三档之后，`_build` 里那条「预算耗尽 = Unknown」的退出码
// 契约（`docs/exit-codes.md` 的 `3`）必须原样成立。这里在**大历史**上锁一次，
// 与 `cli_exit_code_test.mbt` 的 13 操作夹具互补：那一条测「口径一致」，
// 这一条测「规模放大后口径不变」，并顺带锁住 `--budget-ms 0` 仍是「不设期限」。

///|
/// 把一份 2000 操作的合法历史写进 `_build/`（已被 .gitignore 覆盖），返回路径。
///
/// 用库自己的生成器而不是手写 JSONL：这份夹具的价值在于「规模」，手写 2000 行
/// 既不可读也不保证线性一致。
fn lc_big_history_path() -> String {
  let dir = "_build/lincheck_cli_test"
  let path = dir + "/big_2000.jsonl"
  let h = @lib.generate_consistent(
    @lib.register_model(),
    @lib.GenConfig::new(4, 500, 7, 0.5),
  )
  let ok = try {
    if !@fs.path_exists(dir) {
      @fs.create_dir(dir)
    }
    @fs.write_string_to_file(path, h.to_jsonl())
    true
  } catch {
    _ => false
  }
  if ok {
    path
  } else {
    ""
  }
}

///|
/// 1 ms 预算下搜索必然被截断 → 退出码 `3`（不是 `1`）；`0` 预算不设期限 → `0`。
///
/// 修复前这一对也是 `3` / `0`（旧实现在第 256 个节点超时，方向本来就对），
/// 所以它是**守护用例**：它防的是「把轮询改密之后，截断路径被绕过去、
/// 没跑完的搜索被渲染成结论」这类反向退化。真正在旧轮询下会红的是
/// `src/audit_budget_poll_test.mbt`（它断言首个检查点不再是第 256 个节点）。
test "budget: 截断的搜索仍是 exit 3，--budget-ms 0 仍不设期限" {
  let path = lc_big_history_path()
  if path.length() == 0 {
    fail("夹具写入失败")
  }
  // 1ms：2000 操作的完整搜索约 70ms（本机实测），1ms 内被截断 → 没有结论 → 3。
  //
  // 2026-11-17 审计 LC-13：这条原本严格断言 `3`。结论方向是对的（真跑完过 70ms，
  // 要「1 ms 搜完」得比本机快 70 倍以上），但它仍然是**机器速度**进断言——
  // 只要落在一个快得多（或负载截然不同）的环境上就会红，而实现一点没错。
  // 「截断的搜索绝不返回 1」才是契约；`0`（快机器真跑完了）与 `3`（如实说不知道）
  // 都是合法结论。所以这里锁「绝不是 1」，另用一份**确定会超时**的长历史
  // （`cli_exit_code_test.mbt` 的 1201 操作夹具）把 `3` 那一档钉死。
  let tight = run([
    "lincheck", "check", "--history", path, "--model", "register", "--budget-ms",
    "1",
  ])
  assert_true(tight == 0 || tight == 3)
  // 0：`<= 0` 表示不设期限，必须真的跑完并给出结论（这份历史线性一致 → 0）
  inspect(
    run([
      "lincheck", "check", "--history", path, "--model", "register", "--budget-ms",
      "0",
    ]),
    content="0",
  )
  // 同一份历史、默认预算：结论一致，说明上面那条 0 不是巧合
  inspect(
    run(["lincheck", "check", "--history", path, "--model", "register"]),
    content="0",
  )
}
