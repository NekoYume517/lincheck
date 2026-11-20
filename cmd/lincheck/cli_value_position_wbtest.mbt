// cli_value_position_wbtest.mbt — 值位分类是**一个**判据，不是六个
//
// 锁定的缺陷（2026-11-21 审计 LC-27，11-21 轮 #7）：
//
// 上一轮（LC-20）只把 `--history` 的短选项分类修好，其余五个带值参数仍然
// 「照单全收」，于是同一条命令对不同参数的错误信息不一致：
//
// ```text
// check --history -h  → 参数错误（缺值或数值非法）         ← 正确
// check --model   -h  → 未知模型 -h（可选 register, …）    ← 把选项当模型名
// ```
//
// `--model -h` 的退出码同样是 2（未知模型也是用法错误），所以它不是「结论
// 错误」，而是**诊断指向错误**：用户看到「未知模型 -h」会去查模型列表，而真正
// 的问题是 `--model` 后面缺了值。同族还有 `--model -0.5`、`--model -x`。
//
// 判据统一成一条：值位以 `-` 开头时，**只有该值位的语法能接受它**才算值。
// 合法负值一个都不能被误伤：
// - `--seed -1`（`gen` 接受，seed 可为负）/ `--budget-ms -0`（0/负数 = 不设
//   上限，docs/exit-codes.md §budget）/ `--concurrency -0.5`（会走域判据，
//   不是缺值）。
// 这三条在改前就是 exit 0，改后必须仍然 exit 0 —— 这一半是本测试的重点。

///|
test "LC-27: 值位分类表（长选项一律缺值；负数按语法放行；其余短选项按缺值）" {
  // 长选项：所有值位都是缺值
  for
    flag in [
      "--history", "--model", "--budget-ms", "--seeds", "--processes", "--ops", "--seed",
      "--concurrency",
    ] {
    assert_true(value_is_option(flag, "--json"))
    assert_true(value_is_option(flag, "--help"))
  }
  // 路径与模型名：单个 '-' 前缀一律按选项（真实路径写成 './-name'）
  assert_true(value_is_option("--history", "-h"))
  assert_true(value_is_option("--history", "-0.5"))
  assert_true(value_is_option("--model", "-h"))
  assert_true(value_is_option("--model", "-0.5"))
  // 整数位：语法接受的负数就是值
  assert_false(value_is_option("--seed", "-1"))
  assert_false(value_is_option("--budget-ms", "-0"))
  assert_false(value_is_option("--ops", "-2147483648"))
  assert_false(value_is_option("--processes", "-0005"))
  // 整数位：语法不接受的短选项是缺值（`-h` 不是数）
  assert_true(value_is_option("--seed", "-h"))
  assert_true(value_is_option("--budget-ms", "-h"))
  // 小数位：语法接受的负小数是值；`-h` 不是
  assert_false(value_is_option("--concurrency", "-0.5"))
  assert_false(value_is_option("--concurrency", "-0"))
  assert_true(value_is_option("--concurrency", "-h"))
  // 不以 '-' 开头的串永远是值
  assert_false(value_is_option("--model", "register"))
  assert_false(value_is_option("--history", "examples/register_ok.jsonl"))
}

///|
test "LC-27 守护: 合法负值不被缺值判据误伤（CLI 端到端 exit 0）" {
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "1", "--ops", "2",
      "--seed", "-1",
    ]),
    content="0",
  )
  inspect(
    run([
      "lincheck", "check", "--history", "examples/register_ok.jsonl", "--model",
      "register", "--budget-ms", "-0",
    ]),
    content="0",
  )
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "1", "--ops", "2",
      "--seed", "1", "--concurrency", "-0.0",
    ]),
    content="0",
  )
}

///|
test "LC-27: 值位写成短选项时按缺值报用法错误（exit 2）" {
  // 三条验收：之前 `--model -h` 走「未知模型 -h」，现在统一走缺值路径。
  inspect(
    run([
      "lincheck", "check", "--history", "examples/register_ok.jsonl", "--model",
      "-h",
    ]),
    content="2",
  )
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "1", "--ops", "2",
      "--seed", "-h",
    ]),
    content="2",
  )
  inspect(
    run([
      "lincheck", "check", "--history", "examples/register_ok.jsonl", "--model",
      "register", "--budget-ms", "-h",
    ]),
    content="2",
  )
}
