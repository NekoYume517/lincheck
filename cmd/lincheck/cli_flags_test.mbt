// ============================================================================
// LC-4：参数白名单必须按子命令精确化
//
// 攻击面（2026-11-17 审计 LC-4）：`parse_from` 对五个子命令共用一套 flag，
// 于是别的子命令的参数被收下后**静默丢弃**：
//
//     $ lincheck selfcheck --model register --seeds 2 --budget-ms 1
//     # 收下 --budget-ms，但 cmd_selfcheck 用的是 CheckConfig::default()，
//     # 预算完全不生效，输出与不带该参数逐字节相同，exit 0
//
// 「只能打印不能生效的守卫」是缺陷温床（HANDOVER §19.8-4）：用户以为自己限了
// 预算 / 换了模式，工具照旧跑默认档。正确做法是**不接受的参数就报用法错误**，
// 并顺带告诉他这个参数属于哪个子命令。
//
// 白名单（`docs/exit-codes.md` 只承诺 check/minimize/visualize 吃 --budget-ms）：
//
//   check      --history --model --budget-ms --json
//   minimize   --history --model --budget-ms --json
//   visualize  --history --model --budget-ms
//   gen        --model --processes --ops --seed --concurrency --consistent/--random/--inject
//   selfcheck  --model --processes --ops --seeds
// ============================================================================

///|
/// 一份**违规**历史（3 个操作，`examples/register_bad.jsonl` 同款）。
/// 用它是因为退出码可区分：白名单生效 → 2，未生效 → 1。
fn lc_flags_bad_text() -> String {
  "{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":10}\n" +
  "{\"id\":1,\"process\":1,\"kind\":{\"tag\":\"Write\",\"value\":2},\"result\":{\"tag\":\"Ok\"},\"start\":12,\"end\":20}\n" +
  "{\"id\":2,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":1},\"start\":30,\"end\":40}\n"
}

///|
test "LC-4: 别子命令的参数必须报用法错误（不再静默丢弃）" {
  let path = lc_write("flags_bad.jsonl", lc_flags_bad_text())
  if path.length() == 0 {
    fail("夹具写入失败")
  }
  // --budget-ms 只属于 check / minimize / visualize
  inspect(
    run([
      "lincheck", "selfcheck", "--model", "register", "--seeds", "2", "--budget-ms",
      "1",
    ]),
    content="2",
  )
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "2",
      "--budget-ms", "1",
    ]),
    content="2",
  )
  // --seeds 只属于 selfcheck
  inspect(
    run([
      "lincheck", "check", "--history", path, "--model", "register", "--seeds", "2",
    ]),
    content="2",
  )
  // --ops / --processes 属于 gen / selfcheck，不属于三个读历史的子命令
  inspect(
    run([
      "lincheck", "check", "--history", path, "--model", "register", "--ops", "2",
    ]),
    content="2",
  )
  inspect(
    run([
      "lincheck", "minimize", "--history", path, "--model", "register", "--processes",
      "2",
    ]),
    content="2",
  )
  // --json 只属于 check / minimize
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "2",
      "--json",
    ]),
    content="2",
  )
  inspect(
    run(["lincheck", "visualize", "--history", path, "--json"]),
    content="2",
  )
  // --consistent / --random / --inject 只属于 gen
  inspect(
    run([
      "lincheck", "check", "--history", path, "--model", "register", "--consistent",
    ]),
    content="2",
  )
  // --history 不属于生成类子命令
  inspect(
    run([
      "lincheck", "selfcheck", "--model", "register", "--seeds", "1", "--history",
      path,
    ]),
    content="2",
  )
}

///|
/// 守护：**每个子命令自己的参数一个都不能被误伤**。没有这一条，
/// 「所有 flag 一律拒绝」也能让上面那十条通过。
test "LC-4 守护: 各子命令自身的参数仍然生效" {
  let path = lc_write("flags_bad.jsonl", lc_flags_bad_text())
  if path.length() == 0 {
    fail("夹具写入失败")
  }
  // check / minimize：--history --model --budget-ms --json 全套
  inspect(
    run([
      "lincheck", "check", "--history", path, "--model", "register", "--budget-ms",
      "5000", "--json",
    ]),
    content="1",
  )
  inspect(
    run([
      "lincheck", "minimize", "--history", path, "--model", "register", "--budget-ms",
      "5000", "--json",
    ]),
    content="1",
  )
  // visualize：--budget-ms
  inspect(
    run([
      "lincheck", "visualize", "--history", path, "--model", "register", "--budget-ms",
      "5000",
    ]),
    content="1",
  )
  // gen：三个模式 + --seed/--concurrency 都要能一起用
  for mode in ["--consistent", "--random", "--inject"] {
    inspect(
      run([
        "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "3",
        "--seed", "7", "--concurrency", "0.5", mode,
      ]),
      content="0",
    )
  }
  // selfcheck：--seeds/--ops/--processes
  inspect(
    run([
      "lincheck", "selfcheck", "--model", "register", "--seeds", "2", "--ops", "2",
      "--processes", "2",
    ]),
    content="0",
  )
}

///|
/// 未知参数仍然走原有的「参数错误」路径（exit 2），不能因为白名单改造而漏掉。
test "LC-4 守护: 未知参数仍是用法错误" {
  inspect(
    run(["lincheck", "check", "--model", "register", "--nonsense", "1"]),
    content="2",
  )
}
