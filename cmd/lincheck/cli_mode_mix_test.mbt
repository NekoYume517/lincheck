// LC-21：gen 的三个生成模式互斥，不得由出现顺序静默决定胜者。
// 用法契约写的是 [--consistent|--random|--inject]；旧解析器允许混用，
// 每遇到一个就覆盖 cli.mode，导致用户写出的多个约束只有最后一个生效。

///|
fn mixed_mode_args(first : String, second : String) -> Array[String] {
  [
    "lincheck", "gen", "--model", "register", "--processes", "1", "--ops", "1", "--seed",
    "1", first, second,
  ]
}

///|
test "LC-21: random 与 inject 不得混用" {
  inspect(run(mixed_mode_args("--random", "--inject")), content="2")
}

///|
test "LC-21: consistent 与 random 不得混用" {
  inspect(run(mixed_mode_args("--consistent", "--random")), content="2")
}

///|
test "LC-21: 单个模式仍按原契约放行" {
  for mode in ["--consistent", "--random", "--inject"] {
    inspect(
      run([
        "lincheck", "gen", "--model", "register", "--processes", "1", "--ops", "1",
        "--seed", "1", mode,
      ]),
      content="0",
    )
  }
}
