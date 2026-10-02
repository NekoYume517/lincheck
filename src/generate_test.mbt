// ============================================================================
// 生成器测试（白盒）
// ============================================================================

///|
fn reg_model() -> AnyModel {
  Register(register_model())
}

///|
/// 把历史串成可比较的签名（用于确定性断言）
fn signature(h : History) -> String {
  let sb = StringBuilder()
  for op in h.operations {
    sb.write_string(op.id.to_string())
    sb.write_char('|')
    sb.write_string(op.process.to_string())
    sb.write_char('|')
    sb.write_string(kind_label(op.kind))
    sb.write_char('|')
    sb.write_string(result_label(op.result))
    sb.write_char('|')
    sb.write_string(op.start.to_string())
    sb.write_char('|')
    sb.write_string(op.end.to_string())
    sb.write_char(';')
  }
  sb.to_string()
}

///|
test "rng is deterministic per seed" {
  let a = Rng::new(7)
  let b = Rng::new(7)
  let mut i = 0
  while i < 20 {
    assert_eq(a.next(), b.next())
    i = i + 1
  }
}

///|
test "rng below stays in range" {
  let r = Rng::new(99)
  let mut i = 0
  while i < 200 {
    let v = r.below(5)
    assert_true(v >= 0 && v < 5)
    i = i + 1
  }
}

///|
test "generate_consistent is deterministic" {
  let cfg = GenConfig::new(3, 4, 42, 0.5)
  let a = generate_consistent(register_model(), cfg)
  let b = generate_consistent(register_model(), cfg)
  assert_eq(a.length(), b.length())
  assert_eq(signature(a), signature(b))
}

///|
test "generate_consistent produces expected op count" {
  let cfg = GenConfig::new(3, 4, 1, 0.0)
  let h = generate_consistent(register_model(), cfg)
  assert_eq(h.length(), 12)
}

///|
test "generate_consistent replays exactly in time order" {
  // 串行模式下时间顺序就是那条唯一全序：按 start 重放必须逐条命中结果
  let cfg = GenConfig::new(2, 6, 3, 0.0)
  let h = generate_consistent(register_model(), cfg)
  let ops = h.operations.copy()
  ops.sort_by(fn(a, b) {
    if a.start == b.start {
      a.id - b.id
    } else if a.start < b.start {
      -1
    } else {
      1
    }
  })
  let mut state = register_model().init()
  for op in ops {
    match register_model().apply(state, op.kind) {
      Some((next, expected)) => {
        assert_true(OpResult::equal(expected, op.result))
        state = next
      }
      None => assert_true(false)
    }
  }
  // 且整份历史线性一致
  let outcome = check_with(h, register_model(), CheckConfig::default())
  assert_true(outcome is Linearizable)
}

///|
test "generate_consistent covers serial and wide concurrency" {
  let serial = generate_consistent(
    register_model(),
    GenConfig::new(2, 3, 5, 0.0),
  )
  let wide = generate_consistent(register_model(), GenConfig::new(2, 3, 5, 1.0))
  assert_eq(serial.length(), 6)
  assert_eq(wide.length(), 6)
  // 高并发下必然存在重叠区间（宽区间把时间轴撑开）
  let mut overlap = false
  for a in wide.operations {
    for b in wide.operations {
      if a.id < b.id && concurrent(a, b) {
        overlap = true
      }
    }
  }
  assert_true(overlap)
}

///|
test "generate_random is deterministic and complete" {
  let cfg = GenConfig::new(3, 3, 11, 0.6)
  let a = generate_random(register_model(), cfg)
  let b = generate_random(register_model(), cfg)
  assert_eq(a.length(), b.length())
  assert_eq(signature(a), signature(b))
  assert_eq(a.length(), 9)
}

///|
test "different seeds give different histories" {
  let a = generate_consistent(register_model(), GenConfig::new(3, 5, 1, 0.5))
  let b = generate_consistent(register_model(), GenConfig::new(3, 5, 2, 0.5))
  assert_true(signature(a) != signature(b))
}

///|
test "generate_consistent histories are linearizable" {
  // 核心元测试：合法生成器产物必须全部通过检查
  let mut seed = 1
  while seed <= 60 {
    let cfg = GenConfig::new(
      2 + seed % 3,
      3,
      seed,
      (seed % 10).to_double() / 10.0,
    )
    let h = generate_consistent(register_model(), cfg)
    let outcome = check_with(h, register_model(), CheckConfig::default())
    assert_true(outcome is Linearizable)
    seed = seed + 1
  }
}

///|
test "generate_consistent is linearizable under full concurrency" {
  let mut seed = 1
  while seed <= 25 {
    let cfg = GenConfig::new(3, 4, seed, 1.0)
    let h = generate_consistent(register_model(), cfg)
    let outcome = check_with(h, register_model(), CheckConfig::default())
    assert_true(outcome is Linearizable)
    seed = seed + 1
  }
}

///|
test "inject_violation creates a real violation" {
  let mut seed = 1
  let mut broken = 0
  while seed <= 20 {
    let base = generate_consistent(
      register_model(),
      GenConfig::new(3, 4, seed, 0.3),
    )
    let bad = inject_violation(base, reg_model(), seed)
    let outcome = check_with(bad, register_model(), CheckConfig::default())
    if outcome is Violation(_) {
      broken = broken + 1
    }
    seed = seed + 1
  }
  // 绝大多数用例应被成功注入（个别小历史没有可破坏的单点）
  assert_true(broken >= 15)
}

///|
test "inject_violation is deterministic" {
  let base = generate_consistent(register_model(), GenConfig::new(3, 4, 9, 0.3))
  let a = inject_violation(base, reg_model(), 5)
  let b = inject_violation(base, reg_model(), 5)
  assert_eq(signature(a), signature(b))
}

///|
test "inject_violation keeps op count" {
  let base = generate_consistent(
    register_model(),
    GenConfig::new(2, 4, 17, 0.2),
  )
  let bad = inject_violation(base, reg_model(), 3)
  assert_eq(base.length(), bad.length())
}

///|
test "gen config default" {
  let c = GenConfig::default()
  inspect(c.processes, content="3")
  inspect(c.ops_per_process, content="4")
  inspect(c.seed, content="42")
}

///|
test "generate with zero ops is empty" {
  let h = generate_consistent(register_model(), GenConfig::new(3, 0, 5, 0.5))
  inspect(h.length(), content="0")
}
