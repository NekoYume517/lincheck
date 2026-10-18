// audit2_test.mbt — 第二轮审查发现的回归测试（白盒）
//
// 锁定的缺陷：
// 1. JSON 数值曾被 to_int()/to_int64() 静默截断/回绕：`"id":1.5` 解析成 1、
//    `"id":4294967297` 解析成 1。契约要求非法行报 BadLine，不做有损转换。
// 2. happens-before 证据曾按 id 去重：重复 id 的真实前驱被误删（id 不保证唯一）。
// 3. Expl 的 pair 缓存键曾用 lo*100003+hi：id 较大时 Int32 乘法回绕，
//    不同操作对映射到同一键，判定结果跨对污染。

// ============================================================
// 1. JSON 数值解析：截断/回绕必须报 BadLine
// ============================================================

///|
/// 自带助手：保留 HistoryError 构造器，便于匹配 BadLine。
fn parse_row(text : String) -> Result[History, HistoryError] {
  try {
    let r : Result[History, HistoryError] = History::from_jsonl(text)
    r
  } catch {
    _ => Err(BadLine(-1, "unexpected raise"))
  }
}

///|
test "审计2：小数 id 拒绝而不是截断" {
  match
    parse_row(
      "{\"id\":1.5,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":0,\"end\":1}",
    ) {
    Err(BadLine(_, _)) => assert_true(true)
    Ok(_) => inspect(false, content="小数 id 必须报 BadLine")
    Err(_) => assert_true(false)
  }
}

///|
test "审计2：超 Int32 范围的 id 拒绝而不是回绕" {
  match
    parse_row(
      "{\"id\":4294967297,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":0,\"end\":1}",
    ) {
    Err(BadLine(_, _)) => assert_true(true)
    Ok(_) => inspect(false, content="回绕的 id 必须报 BadLine")
    Err(_) => assert_true(false)
  }
}

///|
test "审计2：合法边界整数仍然接受" {
  match
    parse_row(
      "{\"id\":-2147483648,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":0,\"end\":1}",
    ) {
    Ok(h) => assert_eq(h.operations[0].id, -2147483648)
    Err(BadLine(_, _)) => inspect(false, content="Int32 边界值必须接受")
    Err(_) => inspect(false, content="Int32 边界值必须接受")
  }
}

// ============================================================
// 2. happens-before 证据：重复 id 不再误删前驱
// ============================================================

///|
/// 构造重复 id 的违规历史：两个同 id 操作，其一 end < 另一 start，
/// 构建解释文本时按 id 过滤曾把真实前驱丢掉。
fn dup_id_history() -> History {
  let h = History::new()
  // 前驱：id 与坏操作同为 5
  h.add(Operation::{
    id: 5,
    process: 0,
    kind: Write(1),
    result: Ok,
    start: 0L,
    end: 5L,
  })
  // 旧状态写入在 [20..25]，坏读在 [30..35] 之前完成
  h.add(Operation::{
    id: 5,
    process: 1,
    kind: Write(0),
    result: Ok,
    start: 20L,
    end: 25L,
  })
  // 坏操作：读到 2——之前只有 Write(1)（end=5 < start=10，被钉死在前），
  // 模型在此状态只能给出 1；解释文本的「被迫先于它完成的操作」清单
  // 应包含这条同 id 前驱。
  h.add(Operation::{
    id: 5,
    process: 2,
    kind: Read,
    result: Value(2),
    start: 10L,
    end: 15L,
  })
  h
}

///|
test "审计2：解释文本包含同 id 的 happens-before 前驱" {
  let h = dup_id_history()
  match check_default(h, model_or_default("register")) {
    Violation(v) => {
      // 旧实现按 id 过滤：id=5 的两个前驱都被 `op.id != bad.id` 丢弃，
      // 文本里不会出现任何「被迫先于它完成的操作」。
      assert_true(v.explanation.contains("被迫先于它完成的操作"))
      assert_true(v.explanation.contains("操作 5 @proc 0"))
    }
    _ => inspect(false, content="该历史应判定为违规")
  }
}

// ============================================================
// 3. Expl 缓存键：大 id 不再碰撞
// ============================================================

///|
test "审计2：pair_key 大 id 碰撞修复" {
  // 旧键 lo*100003+hi：这两对在 32 位乘法下曾映射到同一键
  let a = pair_key(2, 46343)
  let b = pair_key(1, 46344)
  assert_true(a != b)
  // 相同 id 对必须仍是同一键（缓存语义不变）
  assert_eq(pair_key(7, 3), pair_key(3, 7))
}

///|
test "审计2：Expl 跨对缓存不互相污染" {
  let expl = Expl::new()
  let m = model_or_default("register")
  // 大 id：这对组合曾因碰撞复用别人的缓存值
  let w1 = Operation::{
    id: 200000,
    process: 0,
    kind: Write(1),
    result: Ok,
    start: 0L,
    end: 5L,
  }
  let r1 = Operation::{
    id: 300000,
    process: 1,
    kind: Read,
    result: Value(1),
    start: 10L,
    end: 15L,
  }
  let w2 = Operation::{
    id: 400000,
    process: 0,
    kind: Write(2),
    result: Ok,
    start: 20L,
    end: 25L,
  }
  let r2 = Operation::{
    id: 500000,
    process: 1,
    kind: Read,
    result: Value(2),
    start: 30L,
    end: 35L,
  }
  // {W=1, R->1} 合法；{W=2, R->2} 也合法；{R->1, W=2} 违规（读到不存在的值）
  assert_true(expl.pair_explains(w1, r1, m, CheckConfig::default()))
  assert_true(expl.pair_explains(w2, r2, m, CheckConfig::default()))
  assert_true(!expl.pair_explains(r1, w2, m, CheckConfig::default()))
  // 缓存命中路径：再查一遍结果不变
  assert_true(expl.pair_explains(w1, r1, m, CheckConfig::default()))
  assert_true(!expl.pair_explains(r1, w2, m, CheckConfig::default()))
}
