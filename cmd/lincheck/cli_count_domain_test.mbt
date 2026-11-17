// cli_count_domain_test.mbt — `--ops` / `--processes` 的取值域（2026-11-17-b 审计 LC-14）
//
// 库层对规模的钳制是给**程序化调用方**的既有行为：`total_ops_checked` 与两个
// 生成器都把 `processes < 1` 钳成 1、把 `ops_per_process < 0` 钳成 0
// （`src/audit_round6_test.mbt` 锁着这条库级语义）。但 CLI 是用户入口：
//
// ```text
// $ lincheck gen --model register --processes 2 --ops -1 --seed 1
// （无输出）                                              exit 0
// $ lincheck gen --model register --processes -2 --ops 2 --seed 1
// {"id":0,"process":0,...}                                exit 0   # 用户写了 -2 个客户端，拿到 1 个
// ```
//
// `--ops -1` 被悄悄当成「0 条」，于是 `gen` 打出一份**空历史**并以 0 退出；
// 下游 `check` 随即报 `{"verdict":"linearizable","total":0}` —— 一条流水线就此
// 拿到一个「通过」的空结果。这正是 LC-1（`selfcheck --ops 0` 空跑 PASS）在
// **另一条子命令**上的镜像缺口：负数是笔误，不是「零」的另一种写法，
// 显式的空历史只能由 `--ops 0` 表达。

///|
/// 每个子命令一条「负计数」用例：必须先报用法错误（2），不得产出历史。
test "LC-14: gen 的 --ops/--processes 不得为负（不再静默产出空历史）" {
  // 修复前：exit 0 + 空历史（负值被钳成 0）
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "-1",
      "--seed", "1",
    ]),
    content="2",
  )
  // 修复前：exit 0 + 2 条操作（-2 个客户端被钳成 1 个）
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "-2", "--ops", "2",
      "--seed", "1",
    ]),
    content="2",
  )
  // 另外两种模式走同一条校验
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "-1",
      "--seed", "1", "--random",
    ]),
    content="2",
  )
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "-1", "--ops", "2",
      "--seed", "1", "--inject",
    ]),
    content="2",
  )
  // selfcheck 走同一份守卫
  inspect(
    run([
      "lincheck", "selfcheck", "--model", "register", "--seeds", "2", "--processes",
      "-1", "--ops", "3",
    ]),
    content="2",
  )
}

///|
/// 守护（双向验证的另一半）：`0` 与正常规模都必须照旧接受。
///
/// - `--ops 0` 是**显式契约**：产出空历史（`docs/DEMO.md:176`）；
/// - `--processes 0` 钳制为 1 是 2026-11-10 LC-A3 的显式契约（有注释、有测试、
///   DEMO 写明了），本次不动它；
/// - `selfcheck --ops 0` 仍然要拒（LC-1，理由不同：0 条操作等于一次空跑）。
test "LC-14 守护: 零与正规模仍然按既有契约接受" {
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "0",
      "--seed", "1",
    ]),
    content="0",
  )
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "0", "--ops", "2",
      "--seed", "1",
    ]),
    content="0",
  )
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "3",
      "--seed", "1",
    ]),
    content="0",
  )
  inspect(
    run([
      "lincheck", "selfcheck", "--model", "register", "--seeds", "2", "--processes",
      "0", "--ops", "2",
    ]),
    content="0",
  )
  // selfcheck 的零操作规模仍按 LC-1 拒绝（换理由，退出码不变）
  inspect(
    run([
      "lincheck", "selfcheck", "--model", "register", "--seeds", "1", "--processes",
      "3", "--ops", "0",
    ]),
    content="2",
  )
  inspect(
    run([
      "lincheck", "selfcheck", "--model", "register", "--seeds", "1", "--processes",
      "3", "--ops", "-5",
    ]),
    content="2",
  )
}
