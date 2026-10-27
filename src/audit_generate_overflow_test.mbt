// audit_generate_overflow_test.mbt — `gen` 的规模参数溢出（对抗性审计 2026-10-27，LC-9）
//
// 缺陷：`generate_consistent` / `generate_random` 都用
//   let total = processes * per_proc
// 计算循环上界，两个操作数都是 Int32。`--processes 65536 --ops 65536` 时乘积
// 在 Int32 回绕成 **0**，于是生成器安静地造出一份**空历史**并以 exit 0 退出：
//
//   $ lincheck gen --model register --processes 65536 --ops 65536 --seed 1 > h.jsonl
//   $ wc -c h.jsonl        # 只有 1 个换行
//   $ lincheck check --history h.jsonl --model register --json
//   {"verdict":"linearizable","ops":0}          # 请求了 42 亿个操作，报「一切正常」
//
// 「请求 N 个操作、静默产出 0 个、退出码 0」会让调用方无法区分「生成成功」与
// 「什么都没生成」。`docs/exit-codes.md` 把参数问题定义为 `2`（用法错误），
// `parse_int_arg` 对单值溢出也报 `2` —— 乘积溢出应当同口径。

///|
test "LC-9: 规模乘积校验 —— 溢出必须被拒" {
  // 回绕成 0（最危险：连「负数 → 循环不执行」的信号都没有）
  inspect(total_ops_checked(65536, 65536).is_empty(), content="true")
  // 回绕成负数
  inspect(total_ops_checked(46341, 46341).is_empty(), content="true")
  inspect(total_ops_checked(65536, 65535).is_empty(), content="true")
  inspect(total_ops_checked(2, 1073741824).is_empty(), content="true")
  inspect(total_ops_checked(1073741824, 2).is_empty(), content="true")
  // 回绕成正数（更隐蔽：会真的生成一份大小完全不对的历史）
  inspect(total_ops_checked(65537, 65536).is_empty(), content="true")
  inspect(total_ops_checked(65537, 65537).is_empty(), content="true")
}

///|
test "LC-9: 规模乘积校验 —— 正常值与边界值必须接受" {
  inspect(total_ops_checked(3, 4), content="Some(12)")
  inspect(total_ops_checked(1, 0), content="Some(0)")
  inspect(total_ops_checked(0, 5), content="Some(5)")
  inspect(total_ops_checked(-7, 5), content="Some(5)")
  inspect(total_ops_checked(2, -3), content="Some(0)")
  inspect(total_ops_checked(1, 1000), content="Some(1000)")
  // Int32 内最大的不溢出乘积
  inspect(total_ops_checked(46340, 46340), content="Some(2147395600)")
  // clamp 之后的边界：65536 × 32767 = 2^31 − 65536 = 2147418112 < 2^31，仍应接受
  inspect(total_ops_checked(65536, 32767), content="Some(2147418112)")
  // 65536 × 32768 = 2^31，正好越界
  inspect(total_ops_checked(65536, 32768).is_empty(), content="true")
}

///|
test "LC-9: 生成的历史条数等于校验后的乘积（不再被回绕截断）" {
  // 正常路径不受影响：总数 = processes × ops_per_process
  for procs in [1, 2, 3, 5] {
    for ops in [0, 1, 4, 7] {
      let h = generate_consistent(
        reg_model(),
        GenConfig::new(procs, ops, 1, 0.5),
      )
      assert_eq(h.length(), procs * ops)
    }
  }
}

///|
test "LC-9 守护: 生成上限内的最大请求仍是正常规模而非回绕成小值" {
  // 1000 × 1000 = 1000000：不溢出，必须真的生成 100 万条
  let h = generate_consistent(reg_model(), GenConfig::new(1000, 1000, 1, 0.0))
  assert_eq(h.length(), 1000000)
}
