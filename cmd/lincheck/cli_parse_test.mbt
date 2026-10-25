// cli_parse_test.mbt — CLI 参数解析的回归测试（白盒，直接测 parse_int_arg / parse_double_arg）
//
// 锁定的缺陷：
// - 整数溢出曾静默回绕：`--seeds 3000000000` 被当成 1 跑完
//   （acc * 10 + digit 无溢出防护，回绕成什么数就跑什么数）。
//   现在溢出必须返回 None → 用法错误。
// - 浮点符号曾按「段」解析：`-0.5` 的负号落在整数段（0）上被丢掉，
//   实际得到 +0.5；`-1.5` 得到 -0.5。现在小数段恒按无符号解析，
//   最后统一乘整体符号。

///|
test "parse_int_arg：常规与负数" {
  assert_eq(parse_int_arg("100"), Some(100))
  assert_eq(parse_int_arg("-7"), Some(-7))
  assert_eq(parse_int_arg("0"), Some(0))
}

///|
test "parse_int_arg：非数字与空串拒绝" {
  assert_true(parse_int_arg("").is_empty())
  assert_true(parse_int_arg("abc").is_empty())
  assert_true(parse_int_arg("12a").is_empty())
  assert_true(parse_int_arg("-").is_empty())
}

///|
test "parse_int_arg：溢出必须拒绝而不是回绕" {
  // 3000000000 > Int32 上限 2147483647，曾经回绕成某个小数被静默接受
  assert_true(parse_int_arg("3000000000").is_empty())
  assert_true(parse_int_arg("2147483648").is_empty())
  assert_true(parse_int_arg("99999999999").is_empty())
  // 边界值必须仍然接受
  assert_eq(parse_int_arg("2147483647"), Some(2147483647))
}

///|
test "parse_int_arg：-0 是 0，-2147483648 才是 Int32 最小值" {
  // 回归：旧的 `acc == 0` 放行分支把 `-0` 错当成 -2147483648，
  // 而真正的 `-2147483648` 在累加循环里就被溢出检查拒成 None——
  // 两个边界都错，且方向相反。
  assert_eq(parse_int_arg("-0"), Some(0))
  assert_eq(parse_int_arg("-2147483648"), Some(-2147483648))
  assert_true(parse_int_arg("-2147483649").is_empty())
  // 前导零形态与正数侧一致地接受（"0000"/"-0000" 都是 0）
  assert_eq(parse_int_arg("-0000"), Some(0))
}

///|
test "parse_double_arg：整数值与符号" {
  assert_eq(parse_double_arg("1"), Some(1.0))
  assert_eq(parse_double_arg("-2"), Some(-2.0))
}

///|
test "parse_double_arg：负号对整个数值生效（曾丢在整数段上）" {
  assert_eq(parse_double_arg("0.5"), Some(0.5))
  // 回归：曾返回 +0.5
  assert_eq(parse_double_arg("-0.5"), Some(-0.5))
  // 回归：曾返回 -0.5
  assert_eq(parse_double_arg("-1.5"), Some(-1.5))
  assert_eq(parse_double_arg("-0.05"), Some(-0.05))
}

///|
test "parse_double_arg：非法形态拒绝" {
  assert_true(parse_double_arg("").is_empty())
  assert_true(parse_double_arg("abc").is_empty())
  assert_true(parse_double_arg("1.2.3").is_empty())
  assert_true(parse_double_arg("1.").is_empty())
  assert_true(parse_double_arg(".5").is_empty())
  assert_true(parse_double_arg("1.5x").is_empty())
}
