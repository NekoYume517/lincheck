// cli_data_error_test.mbt — 输入数据错误的可定位性（对抗性审计 2026-10-27，LC-10）
//
// 缺陷：`load_history` 用 `Err(_)` 把 `@lib.BadLine(line_no, reason)` 的行号与原因
// 整个丢掉，只留一句 `数据错误：JSONL 解析失败：<路径>`。库层明明已经算好了
// 「从 1 开始的行号 + 具体原因」（`history.mbt` 的注释：报错位置与编辑器里的
// 行号一致），CLI 却把它降级成对几百行历史几乎无法定位的一句话。
//
// 这里直接断言 `jsonl_error_text` 的文本 —— 它是 CLI 可观测输出的一部分。

///|
test "LC-10: 解析失败的错误文本必须带行号与原因" {
  let err : Error = @lib.BadLine(3, "不是合法的 JSON")
  inspect(
    jsonl_error_text("h.jsonl", err),
    content="JSONL 解析失败：h.jsonl（第 3 行：不是合法的 JSON）",
  )
}

///|
test "LC-10: 不同行号/原因都要如实透出（不能写死）" {
  inspect(
    jsonl_error_text("a.jsonl", @lib.BadLine(1, "不是合法的 JSON")),
    content="JSONL 解析失败：a.jsonl（第 1 行：不是合法的 JSON）",
  )
  inspect(
    jsonl_error_text(
      "b.jsonl",
      @lib.BadLine(6, "缺少或非法的 id/process/start/end 字段"),
    ),
    content="JSONL 解析失败：b.jsonl（第 6 行：缺少或非法的 id/process/start/end 字段）",
  )
  inspect(
    jsonl_error_text("c.jsonl", @lib.BadLine(42, "未知的操作 tag: Wat")),
    content="JSONL 解析失败：c.jsonl（第 42 行：未知的操作 tag: Wat）",
  )
}

///|
test "LC-10: 非 BadLine 的错误仍给出不含行号的兜底文本" {
  // 保险：错误类型将来若扩充，这条不会崩，也不会伪造行号。
  let generic : Error = Failure("something else")
  inspect(
    jsonl_error_text("d.jsonl", generic),
    content="JSONL 解析失败：d.jsonl",
  )
}

///|
test "LC-10 守护: 好文件仍能正常加载（错误路径不影响正常路径）" {
  let dir = "_build/lincheck_cli_test"
  let path = dir + "/good_three.jsonl"
  let text = "{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":10}\n" +
    "{\"id\":1,\"process\":1,\"kind\":{\"tag\":\"Write\",\"value\":2},\"result\":{\"tag\":\"Ok\"},\"start\":5,\"end\":15}\n" +
    "{\"id\":2,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":2},\"start\":20,\"end\":30}\n"
  let ok = try {
    if !@fs.path_exists(dir) {
      @fs.create_dir(dir)
    }
    @fs.write_string_to_file(path, text)
    true
  } catch {
    _ => false
  }
  if !ok {
    fail("夹具写入失败")
  }
  inspect(
    run([
      "lincheck", "check", "--history", path, "--model", "register", "--json",
    ]),
    content="0",
  )
}

///|
test "LC-10: 坏文件的退出码仍是 4（数据错误，不是用法错误）" {
  let dir = "_build/lincheck_cli_test"
  let path = dir + "/bad_mid.jsonl"
  let text = "{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":10}\n" +
    "{\"id\":1,\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":10}\n" +
    "THIS IS NOT JSON\n"
  let ok = try {
    if !@fs.path_exists(dir) {
      @fs.create_dir(dir)
    }
    @fs.write_string_to_file(path, text)
    true
  } catch {
    _ => false
  }
  if !ok {
    fail("夹具写入失败")
  }
  // 退出码契约不变：文件读到了、但内容不合法 → 4
  inspect(
    run(["lincheck", "check", "--history", path, "--model", "register"]),
    content="4",
  )
  // 三个子命令都走同一条 load_history
  for cmd in ["minimize", "visualize"] {
    inspect(
      run(["lincheck", cmd, "--history", path, "--model", "register"]),
      content="4",
    )
  }
}
