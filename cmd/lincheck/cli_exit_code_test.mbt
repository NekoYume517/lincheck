// cli_exit_code_test.mbt — CLI 退出码契约的回归测试（白盒，直接调 `run`）
//
// 锁定缺陷（对抗性审计 2026-10-27，LC-7 / LC-8 / LC-9）：
//
// `docs/exit-codes.md` 把 `3` 定义为「没有结论」（预算耗尽 / 证据不完整 /
// 区间非法），把 `1` 定义为「历史确实非线性一致」这一**有效结论**。该文档
// 点名的最坏情形就是「脚本把一次没跑完的搜索记成已发现的并发 bug」。
//
// 实测 `minimize` 与 `visualize` 都踩了这一条：同一份历史、同一个
// `--budget-ms 1`，`check` 如实报 unknown（退出码 3），它们却报
// `non-linearizable`（退出码 1）——各自的 `check` 调用用了硬编码的默认预算，
// 把被截断的搜索结果「跑通」成了结论。退出码是脚本唯一可靠的信号，
// 因此这三条断言直接锁在退出码上。

///|
/// 「1ms 预算内绝无可能搜完」的历史文本。
///
/// 12 个全并发写 + 1 个读到**从未写过**的值的读：搜索空间是 13 个操作的
/// 全排列级，1ms 只够探索数百个节点（实测 256 个就超时），因此无论机器快慢，
/// `--budget-ms 1` 下 `check` 必然返回 Unknown。
fn lc_hard_history_text() -> String {
  let sb = StringBuilder()
  for i in 0..<12 {
    sb.write_string(
      "{\"id\":" +
      i.to_string() +
      ",\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":" +
      (i + 1).to_string() +
      "},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":100}\n",
    )
  }
  sb.write_string(
    "{\"id\":12,\"process\":1,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":99},\"start\":0,\"end\":100}\n",
  )
  sb.to_string()
}

///|
/// 把夹具写进 `_build/`（已被 .gitignore 覆盖，不污染工作树）。
/// 失败返回空串，由调用方报错。
fn lc_hard_history_path() -> String {
  let dir = "_build/lincheck_cli_test"
  let path = dir + "/hard_concurrent.jsonl"
  let ok = try {
    if !@fs.path_exists(dir) {
      @fs.create_dir(dir)
    }
    @fs.write_string_to_file(path, lc_hard_history_text())
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
test "LC-7: 预算耗尽时 minimize 的退出码必须与 check 一致（都是 3）" {
  let path = lc_hard_history_path()
  if path.length() == 0 {
    fail("夹具写入失败")
  }
  let check_code = run([
    "lincheck", "check", "--history", path, "--model", "register", "--budget-ms",
    "1", "--json",
  ])
  let minimize_code = run([
    "lincheck", "minimize", "--history", path, "--model", "register", "--budget-ms",
    "1", "--json",
  ])
  // 先确认夹具确实让 check 无法下结论（否则后面那条断言是空的）
  inspect(check_code, content="3")
  inspect(minimize_code, content="3")
}

///|
test "LC-8: 预算耗尽时 visualize 的退出码必须与 check 一致（都是 3）" {
  let path = lc_hard_history_path()
  if path.length() == 0 {
    fail("夹具写入失败")
  }
  let check_code = run([
    "lincheck", "check", "--history", path, "--model", "register", "--budget-ms",
    "1", "--json",
  ])
  let visualize_code = run([
    "lincheck", "visualize", "--history", path, "--model", "register", "--budget-ms",
    "1",
  ])
  // 同一份历史、同一个预算：visualize 不得用默认 5 秒预算另跑一次搜索
  inspect(check_code, content="3")
  inspect(visualize_code, content="3")
}

// ============================================================
// 守护：修「未知不得报成违规」不能把正常的违规判定也改掉
// ============================================================

///|
/// 把 JSONL 文本写进 `_build/` 下并返回路径（空串 = 失败）。
fn lc_write(name : String, text : String) -> String {
  let dir = "_build/lincheck_cli_test"
  let path = dir + "/" + name
  let ok = try {
    if !@fs.path_exists(dir) {
      @fs.create_dir(dir)
    }
    @fs.write_string_to_file(path, text)
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
test "LC-7 守护：预算充足时 minimize 仍正常判定违规（exit 1）" {
  // 经典 3 操作反例：W=1 与 W=2 不重叠，R 在两个写之后却读到 1。
  let text = "{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":10}\n" +
    "{\"id\":1,\"process\":1,\"kind\":{\"tag\":\"Write\",\"value\":2},\"result\":{\"tag\":\"Ok\"},\"start\":12,\"end\":20}\n" +
    "{\"id\":2,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":1},\"start\":30,\"end\":40}\n"
  let path = lc_write("register_bad.jsonl", text)
  if path.length() == 0 {
    fail("夹具写入失败")
  }
  inspect(
    run([
      "lincheck", "minimize", "--history", path, "--model", "register", "--json",
    ]),
    content="1",
  )
}

///|
/// 长**线性一致**历史的 JSONL 文本：`n` 条顺次（互不重叠）写入 + 1 条读到最后写入的值。
///
/// 构造上只有一个合法全序，`check` 必须线性化全部 `n+1` 条操作（节点数 ≥ n+1），
/// 而单节点成本是 O(n)（缓存键要拼 n 位剩余位串、`min_end_of` 与候选表各扫一遍）。
///
/// 实测（n=1200，本机）：`--budget-ms 1` 只探索到 **1–3 个节点**、`5` 到 **60–80 个**，
/// 而搜完需要 **1201 个节点（约 75 ms）**、默认 5000 ms 稳稳给结论。也就是说
/// 「1 ms 搜得完」要机器比现在快 **70 倍以上**，「5000 ms 搜不完」要慢 **60 倍以上**
/// —— 两头都留了一个数量级以上的余量，所以这份夹具上的结论是**确定**的，
/// 不是「这台机器当时快慢」。这正是旧用例缺的东西。
fn lc_long_linearizable_text(n : Int32) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    let t = i.to_int64() * 10L
    sb.write_string("{\"id\":")
    sb.write_string(i.to_string())
    sb.write_string(",\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":")
    sb.write_string((i + 1).to_string())
    sb.write_string("},\"result\":{\"tag\":\"Ok\"},\"start\":")
    sb.write_string(t.to_string())
    sb.write_string(",\"end\":")
    sb.write_string((t + 9L).to_string())
    sb.write_string("}\n")
    i = i + 1
  }
  let t2 = n.to_int64() * 10L
  sb.write_string("{\"id\":")
  sb.write_string(n.to_string())
  sb.write_string(
    ",\"process\":1,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":",
  )
  sb.write_string(n.to_string())
  sb.write_string("},\"start\":")
  sb.write_string(t2.to_string())
  sb.write_string(",\"end\":")
  sb.write_string((t2 + 9L).to_string())
  sb.write_string("}\n")
  sb.to_string()
}

///|
/// 解析 JSONL 成库层 `History`（失败返回 `None`，由调用方断言）。
fn lc_parse_history(text : String) -> @lib.History? {
  try {
    match @lib.History::from_jsonl(text) {
      Ok(h) => Some(h)
      Err(_) => None
    }
  } catch {
    _ => None
  }
}

///|
/// 线性一致的历史上 `minimize` 绝不造假违规。
///
/// ## 这条用例为什么曾经是 flaky 的（2026-11-13 修正）
///
/// 旧实现用一份 **3 个操作**的夹具，对 `--budget-ms 1 / 5 / 5000` 三档都断言
/// `exit 0`（严格）。3 个操作确实是小问题，但「1 ms 内搜完 3 个操作」根本不是
/// 契约：预算是**墙上时钟**上界，机器一忙（当日 5 个代理并发编译）连第一个
/// 候选都来不及算完 —— 实测同一份 HEAD 单独跑 8/8 全绿，五仓库并发全量跑就红。
///
/// 契约（`docs/exit-codes.md`）说的是两件互不相同的事：
///
/// 1. 预算**够**时必须给出真结论 —— 线性一致的历史上是 `0`，不许是 `1`；
/// 2. 预算**不够**时必须如实说「不知道」—— `3`，同样不许是 `1`。
///
/// 换句话说，`1`（发现违规）在任何预算下都是**错的**，而 `0` / `3` 之间怎么落
/// 取决于机器快慢，断言不许把它写死。旧断言把「机器够快」当成了契约。
test "LC-7 守护：线性一致的历史上 minimize 绝不造假违规（小结 + 大结）" {
  // 两次写重叠 → 并发 → 可以排成 W=2 先、W=1 后，再读到 2。
  let text = "{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":10}\n" +
    "{\"id\":1,\"process\":1,\"kind\":{\"tag\":\"Write\",\"value\":2},\"result\":{\"tag\":\"Ok\"},\"start\":5,\"end\":15}\n" +
    "{\"id\":2,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":2},\"start\":20,\"end\":30}\n"
  let path = lc_write("register_ok_ov.jsonl", text)
  if path.length() == 0 {
    fail("夹具写入失败")
  }
  // 先确认这份夹具确实线性一致（否则下面那条断言没有意义）
  inspect(
    run([
      "lincheck", "check", "--history", path, "--model", "register", "--json",
    ]),
    content="0",
  )
  // 预算充足：必须给出确定结论 `0`。这一档是严格断言，也是「不得凭空造违规」
  // 真正能被机器无关地验证的形态（3 个操作在 5000 ms 内必然搜完）。
  inspect(
    run([
      "lincheck", "minimize", "--history", path, "--model", "register", "--budget-ms",
      "5000", "--json",
    ]),
    content="0",
  )
  // 极小预算：只锁「绝不是 1」。落在 `0`（这台机器快）还是 `3`（如实说不知道）
  // 都是合法结论，把它们写死就是把机器快慢当契约。
  for budget in ["1", "5"] {
    let code = run([
      "lincheck", "minimize", "--history", path, "--model", "register", "--budget-ms",
      budget, "--json",
    ])
    assert_true(code == 0 || code == 3)
  }
  // 上面那条 `code == 0 || code == 3` 如果永远只见到 `0`，就是一条恒真的空断言
  // （这项最擅长的陷阱）。所以另取一份**确定会超时**的长历史，把 `3` 那一档
  // 钉死；同时用库层四态入口确认 CLI 的 `3` 确实来自 `Inconclusive`
  // （`Inconclusive → 3`、`Consistent → 0`、`MinViolation/NoWitness → 1`），
  // 而不是来自某个被渲染成违规的结论。
  let long_text = lc_long_linearizable_text(1200)
  let long_path = lc_write("long_linearizable_1200.jsonl", long_text)
  if long_path.length() == 0 {
    fail("长夹具写入失败")
  }
  let history = lc_parse_history(long_text).unwrap_or(@lib.History::new())
  inspect(history.length(), content="1201")
  let tiny : @lib.CheckConfig = {
    time_budget_ms: 1,
    max_states: 200_000,
    allow_unknown_results: false,
  }
  match
    @lib.minimize_outcome(history, @lib.model_or_default("register"), tiny) {
    @lib.Inconclusive(_) => ()
    @lib.MinViolation(_) => fail("1ms 预算下凭空造出了最小反例")
    @lib.NoWitness =>
      fail(
        "1ms 预算下把线性一致的历史说成「违规但无见证」",
      )
    @lib.Consistent => fail("1ms 预算下声称搜完了 1201 个操作")
  }
  inspect(
    run([
      "lincheck", "minimize", "--history", long_path, "--model", "register", "--budget-ms",
      "1", "--json",
    ]),
    content="3",
  )
  // 同一份长历史、预算充足：必须是 `0`，证明上面的 `3` 是预算造成的而不是历史的问题
  inspect(
    run([
      "lincheck", "minimize", "--history", long_path, "--model", "register", "--budget-ms",
      "5000", "--json",
    ]),
    content="0",
  )
}

///|
test "LC-7 守护：预算充足时大历史的 minimize 仍是 exit 1 并给出真见证" {
  // 8 个操作里只有一对「写已完成、读却读到旧值」，其余是噪声。
  let text = "{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":0,\"end\":2}\n" +
    "{\"id\":1,\"process\":1,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":10}\n" +
    "{\"id\":2,\"process\":2,\"kind\":{\"tag\":\"Write\",\"value\":2},\"result\":{\"tag\":\"Ok\"},\"start\":12,\"end\":20}\n" +
    "{\"id\":3,\"process\":3,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":22,\"end\":24}\n" +
    "{\"id\":4,\"process\":1,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":1},\"start\":30,\"end\":40}\n" +
    "{\"id\":5,\"process\":2,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":50,\"end\":60}\n" +
    "{\"id\":6,\"process\":4,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":1},\"start\":62,\"end\":70}\n" +
    "{\"id\":7,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":72,\"end\":80}\n"
  let path = lc_write("noisy_bad.jsonl", text)
  if path.length() == 0 {
    fail("夹具写入失败")
  }
  inspect(
    run([
      "lincheck", "minimize", "--history", path, "--model", "register", "--json",
    ]),
    content="1",
  )
}

// ============================================================
// LC-9：gen 的规模乘积溢出
// ============================================================

///|
test "LC-9: gen 的 processes × ops 溢出必须报用法错误（exit 2）" {
  // 回绕成 0 的那一档：修前会静默产出空历史并 exit 0
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "65536", "--ops",
      "65536", "--seed", "1",
    ]),
    content="2",
  )
  // 回绕成负数
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "46341", "--ops",
      "46341", "--seed", "1",
    ]),
    content="2",
  )
  // 回绕成正数（更隐蔽：本来会生成规模完全不对的历史）
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "65537", "--ops",
      "65536", "--seed", "1",
    ]),
    content="2",
  )
  // --random 走同一个校验
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "65536", "--ops",
      "65536", "--seed", "1", "--random",
    ]),
    content="2",
  )
}

///|
test "LC-9 守护: gen 的正常规模仍 exit 0（校验不能误伤）" {
  // 注意：这里只用小规模。「不溢出的超大乘积」（如 46340 × 46340 ≈ 21.5 亿）
  // 按设计必须被**接受**，但它会真的去生成 21.5 亿条历史 —— 那条边界由
  // 库层的 total_ops_checked 单测覆盖，不在 CLI 上跑。
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "3",
      "--seed", "1",
    ]),
    content="0",
  )
  inspect(
    run([
      "lincheck", "gen", "--model", "register", "--processes", "1", "--ops", "0",
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
}

// ============================================================
// LC-5：--concurrency 的域外值
// ============================================================

///|
/// `--concurrency` 的取值域是 `[0, 1]`（`API.md` §5：0 = 全串行，1 = 完全随机并发）。
///
/// 修复前实测（2026-11-17 审计 LC-5）：
///
/// ```text
/// $ lincheck gen ... --concurrency 2.5   # 与 --concurrency 1.0 逐字节相同
/// $ lincheck gen ... --concurrency 1.0   # 同上
/// 两条都 exit 0
/// ```
///
/// 库里 `generate_consistent` 的钳制是给程序化调用方的既有行为（保留不动），
/// 但 CLI 是用户入口：把一个越界值悄悄换成边界值，等于替用户改写意图，
/// 用户拿到的那份历史与他写的参数毫无关系。与 `--ops` 越界同口径 → 用法错误。
///
/// 注意「域外」与「小数」是两件事：并发度是期望值不是计数，`0.5` 必须照旧合法
/// （守护用例在下面）。
test "LC-5: --concurrency 域外值必须报用法错误（不得静默钳制）" {
  for v in ["2.5", "-0.5", "-1", "1.0001", "100"] {
    inspect(
      run([
        "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "3",
        "--seed", "1", "--concurrency", v,
      ]),
      content="2",
    )
  }
}

///|
/// 守护：域内值（含小数与两个端点）必须照旧 exit 0 —— 阈值类改动的双向验证，
/// 只验「越界被拒」是半个验证。
test "LC-5 守护: 域内并发度仍然接受（0 / 0.5 / 1）" {
  for v in ["0", "0.5", "0.25", "1"] {
    inspect(
      run([
        "lincheck", "gen", "--model", "register", "--processes", "2", "--ops", "3",
        "--seed", "1", "--concurrency", v,
      ]),
      content="0",
    )
  }
}
