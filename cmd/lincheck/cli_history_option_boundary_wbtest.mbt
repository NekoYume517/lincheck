// 带值参数缺值的同族入口：未知长选项也不是文件路径。
//
// `--history --json` 已由 LC-20 覆盖，但旧实现只识别已知 flag。
// `--history --not-a-real-option` 仍会被当成路径，最终报数据错误（4），
// 而命令行用法错误的契约退出码是 2。

///|
fn history_boundary_write(name : String, text : String) -> String {
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
test "history 不得把选项吞成路径" {
  for command in ["check", "minimize", "visualize"] {
    for option in ["--not-a-real-option", "-h", "-x"] {
      inspect(
        run(["lincheck", command, "--history", option, "--model", "register"]),
        content="2",
      )
    }
  }
}

///|
test "history 的显式相对路径仍按文件处理" {
  let path = history_boundary_write(
    "history_option_boundary.jsonl", "{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":0,\"end\":1}\n",
  )
  if path.length() == 0 {
    fail("夹具写入失败")
  }
  // ./ 明确表达这是路径，而不是选项；三个读历史入口都必须照常接受。
  for command in ["check", "minimize", "visualize"] {
    inspect(
      run(["lincheck", command, "--history", "./" + path, "--model", "register"]),
      content="0",
    )
  }
}
