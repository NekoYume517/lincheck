// LC-20：带值参数不得把下一个选项吞成自己的值。
//
// `check --history --json` 的 `--history` 实际缺值；旧解析器却把路径设为
// "--json"，随后尝试读取这个文件并返回数据错误 exit 4。它既吞掉了 JSON
// 开关，也把命令行用法错误误报成了输入文件错误。

///|
test "LC-20: check 的 history 缺值不得吞掉 json 选项" {
  inspect(
    run(["lincheck", "check", "--model", "register", "--history", "--json"]),
    content="2",
  )
}

///|
test "LC-20: minimize 的 history 缺值不得吞掉 json 选项" {
  inspect(
    run(["lincheck", "minimize", "--model", "register", "--history", "--json"]),
    content="2",
  )
}
