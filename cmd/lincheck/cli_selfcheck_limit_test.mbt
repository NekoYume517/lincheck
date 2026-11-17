// selfcheck 必须与 gen 使用同一份规模校验。
//
// 生成器在库层对溢出/超可行上限的兜底是空历史；CLI 若不先拒绝，就会把
// 「实际没生成任何操作」渲染成 selfcheck PASS + exit 0。

///|
/// 零**操作**规模同样是一次空跑：`total_ops_checked` 说 `Some(0)` 是合法输入
/// （`gen --ops 0` 的既有契约：产出空历史，`DEMO.md:176`），但对 `selfcheck`
/// 来说 0 条操作意味着一条历史都没生成、一次检查都没做。
///
/// 修复前实测（2026-11-17 审计 LC-1）：
///
/// ```text
/// $ lincheck selfcheck --model register --seeds 3 --ops 0 --processes 3
/// selfcheck  model=register  seeds=3  ops/seed=0
///   · 合法历史全部通过：是 ✓
///   · 注入违规被发现：0 / 0
/// 结果：PASS                       exit 0
/// ```
///
/// 而 `API.md:308-312` 明写「也不把生成器兜底的空历史当成一次通过的
/// selfcheck」。上一轮只堵了乘积溢出与 `MAX_GENERATED_OPS` 这一端，零规模
/// 是同一族守卫的另一端。`--ops -5`（负值被钳成 0）与
/// `--processes 0 --ops 0` 走的是同一条路径。
test "selfcheck: 零操作规模不得空跑 PASS（--ops 0 / 负 --ops）" {
  for
    args in [
      [
        "lincheck", "selfcheck", "--model", "register", "--seeds", "2", "--ops",
        "0", "--processes", "3",
      ],
      [
        "lincheck", "selfcheck", "--model", "register", "--seeds", "1", "--ops",
        "-5", "--processes", "3",
      ],
      [
        "lincheck", "selfcheck", "--model", "register", "--seeds", "1", "--ops",
        "0", "--processes", "0",
      ],
    ] {
    // 0 条操作 = 没有可验证的历史：这是不可用的命令行规模（2），
    // 不是「全部通过」（0）。
    inspect(run(args), content="2")
  }
}

///|
/// 守护：把零规模拦下之后，**正常规模必须仍然 PASS**。
///
/// 没有这一条，上面三条可以靠「selfcheck 永远 exit 2」通过——
/// 那正是本项目最贵的陷阱（恒真空断言）。
test "selfcheck 守护: 正常规模仍然 PASS（校验不能误伤）" {
  inspect(
    run([
      "lincheck", "selfcheck", "--model", "register", "--seeds", "3", "--ops", "2",
      "--processes", "2",
    ]),
    content="0",
  )
}

///|
test "selfcheck: 乘积溢出或超上限不得空跑 PASS" {
  for
    args in [
      [
        "lincheck", "selfcheck", "--model", "register", "--seeds", "1", "--processes",
        "65536", "--ops", "65536",
      ],
      [
        "lincheck", "selfcheck", "--model", "register", "--seeds", "1", "--processes",
        "2147483647", "--ops", "1",
      ],
    ] {
    // 与 gen 一致：这是不可用的命令行规模，应报用法错误（2），
    // 而不是把空历史的平凡 Linearizable 当成全部自检通过（0）。
    inspect(run(args), content="2")
  }
}

///|
/// `selfcheck` 的 PASS 必须**每一档都真的注入过一次**（2026-11-17 审计 LC-7）。
///
/// 结论行现在要求 `failed == 0 && injected_missed == 0 && injected == total`。
/// 最后一条今天的取值恒为真（`n ≥ 1 ⇒ 注入必成功`，见
/// `src/audit_inject_invariant_test.mbt` 里的可证明性与 4 模型 × 6 规模断言），
/// 所以这条用例是**可达的守护**：四个模型 × 多个 seed 都必须仍然 PASS。
/// 一旦 `inject_violation` 或 `result_candidates` 被改坏到「合法历史改不动」，
/// 这里会先从 0 变成 1，从而在 CLI 上与库层不变量同时报警。
test "selfcheck 守护: 四模型多档规模仍然 PASS（注入不是空转）" {
  for model in ["register", "counter", "set", "queue"] {
    inspect(
      run([
        "lincheck", "selfcheck", "--model", model, "--seeds", "5", "--ops", "2",
        "--processes", "2",
      ]),
      content="0",
    )
  }
}
