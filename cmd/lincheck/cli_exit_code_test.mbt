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
test "LC-7 守护：线性一致的历史上 minimize 必须 exit 0（不得凭空造违规）" {
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
  for budget in ["1", "5", "5000"] {
    inspect(
      run([
        "lincheck", "minimize", "--history", path, "--model", "register", "--budget-ms",
        budget, "--json",
      ]),
      content="0",
    )
  }
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
