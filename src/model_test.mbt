/// # model.mbt 的测试
///
/// 每个模型都要有正例（合法操作）与反例（非法操作 / 结果不匹配）。

// ============================================================
// 通用工具
// ============================================================

///|
/// 应用一个操作，把 `Option` 展开成便于断言的形式：
/// `Some((state, expected))` → 状态字符串 + 期望结果字符串；
/// `None` → `"illegal"`。
fn[M : Model] apply_str(model : M, state : State, kind : OpKind) -> String {
  match model.apply(state, kind) {
    Some((next, expected)) =>
      state_to_string(next) + " => " + format_op_result(expected)
    None => "illegal"
  }
}

///|
test "poly_hash_matches_spec" {
  // h = 17; h = h * 31 + x
  inspect(poly_hash([]), content="17")
  // 17 * 31 + 1 = 528
  inspect(poly_hash([1]), content="528")
  // 528 * 31 + 2 = 16370
  inspect(poly_hash([1, 2]), content="16370")
  inspect(poly_hash([0]), content="527")
}

///|
test "poly_hash_is_deterministic" {
  let a = poly_hash([1, 2, 3, 4, 5])
  let b = poly_hash([1, 2, 3, 4, 5])
  assert_true(a == b)
  // 不同状态极大概率不同哈希（这里固定验证这一对）
  assert_true(poly_hash([1, 2]) != poly_hash([2, 1]))
}

///|
test "state_to_string_format" {
  inspect(state_to_string([]), content="[]")
  inspect(state_to_string([7]), content="[7]")
  inspect(state_to_string([1, 2, 3]), content="[1,2,3]")
}

///|
test "states_equal_handles_length_and_content" {
  assert_true(states_equal([], []))
  assert_true(states_equal([1, 2], [1, 2]))
  assert_true(!states_equal([1, 2], [1]))
  assert_true(!states_equal([1, 2], [2, 1]))
}

///|
test "state_copy_is_deep" {
  let a = [1, 2, 3]
  let b = state_copy(a)
  b[0] = 99
  inspect(a[0], content="1")
  inspect(b[0], content="99")
}

// ============================================================
// register 模型
// ============================================================

///|
test "register_init_and_name" {
  let m = register_model()
  inspect(m.name(), content="register")
  inspect(state_to_string(m.init()), content="[0]")
}

///|
test "register_write_then_read" {
  let m = register_model()
  inspect(apply_str(m, [0], Write(5)), content="[5] => Ok")
  inspect(apply_str(m, [5], Read), content="[5] => -> 5")
  inspect(apply_str(m, [0], Read), content="[0] => -> 0")
}

///|
test "register_cas_success_and_failure" {
  let m = register_model()
  // 成功：状态从 3 变成 8，返回 true
  inspect(apply_str(m, [3], Cas(3, 8)), content="[8] => -> true")
  // 失败：期望 4 但实际 3，状态不变，返回 false
  inspect(apply_str(m, [3], Cas(4, 8)), content="[3] => -> false")
}

///|
test "register_rejects_queue_ops" {
  let m = register_model()
  inspect(apply_str(m, [0], Append(1)), content="illegal")
  inspect(apply_str(m, [0], Pop), content="illegal")
}

///|
test "register_apply_does_not_mutate_input" {
  let m = register_model()
  let st = [3]
  ignore(m.apply(st, Write(9)))
  // 输入状态必须保持原样（搜索回溯依赖这一点）
  inspect(st[0], content="3")
}

///|
test "register_state_eq_and_hash" {
  let m = register_model()
  assert_true(m.state_eq([1], [1]))
  assert_true(!m.state_eq([1], [2]))
  assert_true(m.state_hash([1]) == poly_hash([1]))
}

// ============================================================
// counter 模型
// ============================================================

///|
test "counter_allows_strict_increase" {
  let m = counter_model()
  inspect(m.name(), content="counter")
  inspect(state_to_string(m.init()), content="[0]")
  inspect(apply_str(m, [0], Write(1)), content="[1] => Ok")
  inspect(apply_str(m, [1], Write(2)), content="[2] => Ok")
}

///|
test "counter_accepts_equal_writes_rejects_decreasing" {
  // 语义：Write 是 set 语义——写入相同值在物理上可能（幂等写），
  // 因此只拒绝「回退」。模型必须只排除物理上不可能的转换；
  // 拒绝 v == current 会把合法历史误报为违规。
  let m = counter_model()
  // 回退：非法
  match m.apply([5], Write(3)) {
    Some(_) => inspect("legal", content="illegal")
    None => inspect("illegal", content="illegal")
  }
  // 原地踏步：合法（幂等写）
  match m.apply([5], Write(5)) {
    Some((st, res)) => {
      inspect(st[0], content="5")
      let ok = match res {
        Ok => true
        _ => false
      }
      inspect(ok, content="true")
    }
    None => inspect("legal", content="illegal")
  }
  // 递增：合法
  match m.apply([5], Write(7)) {
    Some((st, _)) => inspect(st[0], content="7")
    None => inspect("legal", content="illegal")
  }
}

///|
test "counter_read_returns_current" {
  let m = counter_model()
  inspect(apply_str(m, [7], Read), content="[7] => -> 7")
}

// ============================================================
// set 模型
// ============================================================

///|
test "set_init_is_empty" {
  let m = set_model()
  inspect(m.name(), content="set")
  inspect(state_to_string(m.init()), content="[0,0]")
}

///|
test "set_read_is_nondeterministic" {
  let m = set_model()
  // 加入 5：低半掩码第 5 位置位 = 32
  inspect(apply_str(m, [0, 0], Append(5)), content="[32,0] => Ok")
  // apply supplies a legal representative; accepts validates other members.
  inspect(apply_str(m, [32, 0], Read), content="[32,0] => -> 5")
  inspect(apply_str(m, [0, 0], Read), content="[0,0] => -> -1")
}

///|
test "set_supports_bit_32_and_above" {
  let m = set_model()
  // 32 落在高半掩码的第 0 位
  inspect(apply_str(m, [0, 0], Append(32)), content="[0,1] => Ok")
  // 63 落在高半掩码的第 31 位 = 2^31（Int 是 32 位，符号位）
  let out = apply_str(m, [0, 0], Append(63))
  assert_true(out.contains("=> Ok"))
}

///|
test "set_pop_removes_smallest" {
  let m = set_model()
  // 同时含 3 和 7（掩码 = 8 + 128 = 136），Pop 应先移除 3
  let out = apply_str(m, [136, 0], Pop)
  // 136 - 8 = 128 → 只剩 7
  inspect(out, content="[128,0] => -> true")
}

///|
test "set_pop_empty_returns_false" {
  let m = set_model()
  inspect(apply_str(m, [0, 0], Pop), content="[0,0] => -> false")
}

///|
test "set_rejects_out_of_range" {
  let m = set_model()
  inspect(apply_str(m, [0, 0], Append(64)), content="illegal")
  inspect(apply_str(m, [0, 0], Append(-1)), content="illegal")
}

// ============================================================
// queue 模型
// ============================================================

///|
test "queue_init_is_empty" {
  let m = queue_model()
  inspect(m.name(), content="queue")
  inspect(state_to_string(m.init()), content="[0]")
}

///|
test "queue_append_grows_tail" {
  let m = queue_model()
  // 状态 = [长度, e0, e1, ...]
  inspect(apply_str(m, [0], Append(7)), content="[1,7] => Ok")
  inspect(apply_str(m, [1, 7], Append(9)), content="[2,7,9] => Ok")
}

///|
test "queue_pop_is_fifo" {
  let m = queue_model()
  inspect(apply_str(m, [2, 7, 9], Pop), content="[1,9] => -> 7")
  inspect(apply_str(m, [1, 9], Pop), content="[0] => -> 9")
}

///|
test "queue_pop_empty_returns_empty" {
  let m = queue_model()
  inspect(apply_str(m, [0], Pop), content="[0] => -> Empty")
}

///|
test "queue_rejects_register_ops" {
  let m = queue_model()
  inspect(apply_str(m, [0], Write(1)), content="illegal")
  inspect(apply_str(m, [0], Cas(0, 1)), content="illegal")
}

///|
test "queue_read_returns_front" {
  let m = queue_model()
  inspect(apply_str(m, [2, 4, 6], Read), content="[2,4,6] => -> 4")
}

// ============================================================
// AnyModel 分发
// ============================================================

///|
test "anymodel_dispatch_by_name" {
  inspect(model_or_default("register").name(), content="register")
  inspect(model_or_default("counter").name(), content="counter")
  inspect(model_or_default("set").name(), content="set")
  inspect(model_or_default("queue").name(), content="queue")
  // 未知名字回落到 register
  inspect(model_or_default("nonsense").name(), content="register")
}

///|
test "anymodel_forwards_apply" {
  let reg = model_or_default("register")
  inspect(apply_str(reg, [0], Write(4)), content="[4] => Ok")
  let q = model_or_default("queue")
  inspect(apply_str(q, [0], Append(4)), content="[1,4] => Ok")
}

///|
test "anymodel_forwards_hash_and_eq" {
  let m = model_or_default("set")
  assert_true(m.state_hash([1, 2]) == poly_hash([1, 2]))
  assert_true(m.state_eq([1, 2], [1, 2]))
  assert_true(!m.state_eq([1, 2], [2, 1]))
}

///|
test "model_names_are_complete" {
  inspect(model_names().length(), content="4")
}
