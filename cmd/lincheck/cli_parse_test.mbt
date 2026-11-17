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

///|
/// 2026-11-17 审计 LC-2：**每一段都必须是纯数字**，符号只能出现在整个数值的最前面。
///
/// 旧实现把整数段与小数段分别喂给带符号的 `parse_int_arg`，于是：
///
/// ```text
/// parse_double_arg("1.-5") = 1 + (-5)/100 = 0.95     # 负号进了小数段，
///                                                   # 还被算进位数把 scale 放大 10 倍
/// parse_double_arg("0.-1") = 0 + (-1)/100 = -0.01    # 看着正数，解析出负数
/// parse_double_arg("--1.5") = -(-1 + 0.5)  = 0.5     # 两层负号互相抵消
/// ```
///
/// 三者在 CLI 上都表现为「参数被接受、值被悄悄换成另一个数」
/// （`--concurrency 1.-5` 实测等于 `--concurrency 0.95`，exit 0）。
/// 契约是 `parse_double_arg` 只接受「可选符号 + 数字 + 可选小数 + 数字」，
/// 其余一律 `None`（调用方据此报用法错误 exit 2）。
test "parse_double_arg：小数段与整数段不得再带符号" {
  assert_true(parse_double_arg("1.-5").is_empty())
  assert_true(parse_double_arg("0.-1").is_empty())
  assert_true(parse_double_arg("1.+5").is_empty())
  assert_true(parse_double_arg("--1.5").is_empty())
  assert_true(parse_double_arg("-+1.5").is_empty())
  assert_true(parse_double_arg("1.-").is_empty())
  assert_true(parse_double_arg("-1.-5").is_empty())
}

///|
/// 2026-11-17-b 审计 LC-15：**小数段与整数段都不该被当成 Int32 解析**。
///
/// 旧实现把两段都喂给 `parse_int_arg`（Int32），于是「数值本身完全合法、
/// 只是位数多」的拼写被判成「参数值非法」：
///
/// ```text
/// $ lincheck gen ... --concurrency 0.3000000000      # 0.3 的另一种写法
/// 参数错误（缺值或数值非法）                          exit 2
/// $ lincheck gen ... --concurrency 0.12345678901     # 11 位小数
/// 参数错误（缺值或数值非法）                          exit 2
/// ```
///
/// 判据是 Int32 容量（小数段 10 位、且值不得超过 2147483647），与语法
/// `'-'? digits ('.' digits)?` 毫无关系：`0.1234567890`（小数段 1234567890）
/// 被接受，`0.3000000000`（3000000000）被拒——同一种形态，差一位就翻脸。
/// DISCIPLINE §5.6 的口径是「域内合法值不许被守卫误伤」，这里被误伤的是
/// 语法层合法、且落在 `[0, 1]` 域内的值。
///
/// 修法：两段改用 Int64 累加（小数段超过 18 位时截断——Double 在 `[0,1]`
/// 上的分辨率约 1e-16，第 19 位之后对最终值与域判定都不可能有影响），
/// 现有输入的取值逐个不变（`0.25` / `0.5` 走的还是同一句
/// `frac.to_double() / scale`）。
test "LC-15: 小数段/整数段的位数不受 Int32 容量限制（0.3000000000 必须能解析）" {
  // 修复前前四条都返回 None（CLI 上表现为 exit 2「参数值非法」）
  assert_eq(parse_double_arg("0.3000000000"), Some(0.3))
  assert_eq(parse_double_arg("0.1234567890"), Some(0.123456789))
  assert_eq(parse_double_arg("0.123456789012"), Some(0.123456789012))
  assert_eq(parse_double_arg("-0.3000000000"), Some(-0.3))
  // 整数段同理：修复前 `2147483648` 直接判「参数值非法」，交给域判定才对
  assert_eq(parse_double_arg("2147483648"), Some(2147483648.0))
  // 超过 18 位小数：仍然是**可解析的合法数值**，不再报语法错误（值按 18 位截断，
  // 与 Double 的分辨率同量级），且必须留在域内。
  match parse_double_arg("0.9999999999999999999999") {
    Some(v) => assert_true(v > 0.9 && v <= 1.0)
    None => fail("19 位小数的合法数值被误拒")
  }
  match parse_double_arg("0.1234567890123456789") {
    Some(v) => assert_true(v > 0.12 && v < 0.13)
    None => fail("19 位小数的合法数值被误拒")
  }
  // 真正的语法错误仍然必须拒（不能因为放宽位数把 LC-2 的严格化退回去）
  assert_true(parse_double_arg("1.-5").is_empty())
  assert_true(parse_double_arg("0.-1").is_empty())
  assert_true(parse_double_arg("--1.5").is_empty())
  assert_true(parse_double_arg("1.5x").is_empty())
  assert_true(parse_double_arg("1.").is_empty())
  assert_true(parse_double_arg(".5").is_empty())
}

///|
/// 守护：严格化之后，合法形态一个都不能被误伤。
test "parse_double_arg：合法形态仍然逐个接受" {
  assert_eq(parse_double_arg("0"), Some(0.0))
  assert_eq(parse_double_arg("-0"), Some(-0.0))
  assert_eq(parse_double_arg("1"), Some(1.0))
  assert_eq(parse_double_arg("0.5"), Some(0.5))
  assert_eq(parse_double_arg("-0.5"), Some(-0.5))
  assert_eq(parse_double_arg("1.05"), Some(1.05))
  assert_eq(parse_double_arg("0.001"), Some(0.001))
  assert_eq(parse_double_arg("2147483647"), Some(2147483647.0))
}
