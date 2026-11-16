// selfcheck 必须与 gen 使用同一份规模校验。
//
// 生成器在库层对溢出/超可行上限的兜底是空历史；CLI 若不先拒绝，就会把
// 「实际没生成任何操作」渲染成 selfcheck PASS + exit 0。

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
