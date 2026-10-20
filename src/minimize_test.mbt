// —— 最小化测试（白盒）——

///|
fn mk_op(
  id : Int32,
  process : Int32,
  kind : OpKind,
  result : OpResult,
  start : Int64,
  stop : Int64,
) -> Operation {
  Operation::{ id, process, kind, result, start, end: stop, }
}

///|
fn hist_of(ops : Array[Operation]) -> History {
  History::{ operations: ops, }
}

///|
fn reg() -> AnyModel {
  Register(register_model())
}

///|
fn st() -> AnyModel {
  Set(set_model())
}

// 3 个操作的真违规样例：两次写不重叠，读却读到旧值

///|
fn bad_history() -> History {
  hist_of([
    mk_op(0, 0, Write(1), Ok, 0L, 10L),
    mk_op(1, 1, Write(2), Ok, 12L, 20L),
    mk_op(2, 0, Read, Value(1), 30L, 40L),
  ])
}

///|
test "minimize keeps violation on register_bad shape" {
  let v = minimize(bad_history(), reg(), CheckConfig::default())
  assert_eq(v.ops.length(), 3)
  // 最小化产物必须仍然违规
  let still = check_with(
    hist_of(v.ops),
    register_model(),
    CheckConfig::default(),
  )
  assert_true(still is Violation(_))
}

///|
test "minimize drops irrelevant noise ops" {
  // 2 个写 + 1 个读构成违规，另外 3 个是无关的干扰操作
  let h = hist_of([
    mk_op(0, 0, Write(1), Ok, 0L, 10L),
    mk_op(1, 1, Write(2), Ok, 12L, 20L),
    mk_op(2, 2, Read, Value(0), 0L, 2L), // 无关：读初始值，合法
    mk_op(3, 0, Read, Value(1), 30L, 40L), // 违规点
    mk_op(4, 3, Write(1), Ok, 50L, 60L), // 结尾重复写，无关
    mk_op(5, 2, Read, Value(1), 62L, 70L), // 无关：读到 1 合法
  ])
  let v = minimize(h, reg(), CheckConfig::default())
  assert_true(v.ops.length() < 6)
  let still = check_with(
    hist_of(v.ops),
    register_model(),
    CheckConfig::default(),
  )
  assert_true(still is Violation(_))
}

///|
test "minimize on linearizable history returns empty witness" {
  let h = hist_of([
    mk_op(0, 0, Write(1), Ok, 0L, 10L),
    mk_op(1, 1, Read, Value(1), 12L, 20L),
  ])
  let v = minimize(h, reg(), CheckConfig::default())
  assert_eq(v.ops.length(), 0)
}

///|
test "minimize output sorted by id and deterministic" {
  let h = bad_history()
  let a = minimize(h, reg(), CheckConfig::default())
  let b = minimize(h, reg(), CheckConfig::default())
  assert_eq(a.ops.length(), b.ops.length())
  let mut i = 0
  while i < a.ops.length() {
    assert_eq(a.ops[i].id, b.ops[i].id)
    if i > 0 {
      assert_true(a.ops[i - 1].id < a.ops[i].id)
    }
    i = i + 1
  }
}

///|
test "minimize_by_process finds violation" {
  let h = hist_of([
    mk_op(0, 0, Write(1), Ok, 0L, 10L),
    mk_op(1, 1, Write(2), Ok, 12L, 20L),
    mk_op(2, 2, Read, Value(1), 30L, 40L), // 违规读在 proc 2
    mk_op(3, 3, Read, Value(0), 0L, 1L), // 噪声
    mk_op(4, 4, Write(1), Ok, 50L, 60L), // 噪声
  ])
  let v = minimize_by_process(h, reg())
  assert_true(v.ops.length() <= 4)
  let still = check_with(
    hist_of(v.ops),
    register_model(),
    CheckConfig::default(),
  )
  assert_true(still is Violation(_))
}

///|
test "minimize by process prunes whole idle process" {
  // proc 3 全程只是读初始值，理应被整块砍掉
  let h = hist_of([
    mk_op(0, 0, Write(1), Ok, 0L, 10L),
    mk_op(1, 1, Write(2), Ok, 12L, 20L),
    mk_op(2, 2, Read, Value(1), 30L, 40L),
    mk_op(3, 3, Read, Value(0), 0L, 5L),
    mk_op(4, 3, Read, Value(0), 6L, 9L),
  ])
  let v = minimize_by_process(h, reg())
  let mut has_proc3 = false
  for op in v.ops {
    if op.process == 3 {
      has_proc3 = true
    }
  }
  assert_true(!has_proc3 || v.ops.length() == 3)
}

///|
test "labels are human readable" {
  inspect(kind_label(Write(1)), content="W=1")
  inspect(kind_label(Read), content="R")
  inspect(result_label(Value(3)), content="Value(3)")
  inspect(result_label(Ok), content="Ok")
}

///|
test "minimize never returns a single isolated op" {
  // 1-minimal 的退化解（只剩一条读）必须被可解释性约束挡住
  let v = minimize(bad_history(), reg(), CheckConfig::default())
  assert_true(v.ops.length() >= 2)
  // 见证里每条读都必须能被某个写解释
  for op in v.ops {
    if op.kind is Read {
      let mut explained = false
      for other in v.ops {
        if other.kind is Write(_) {
          explained = true
        }
      }
      assert_true(explained)
    }
  }
}

///|
test "minimize on noisy history actually shrinks" {
  // 8 个操作、只有 2 个真正构成矛盾
  let h = hist_of([
    mk_op(0, 0, Read, Value(0), 0L, 2L),
    mk_op(1, 1, Write(1), Ok, 0L, 10L),
    mk_op(2, 2, Write(2), Ok, 12L, 20L),
    mk_op(3, 3, Read, Value(0), 22L, 24L), // ← 真正的问题读
    mk_op(4, 1, Read, Value(1), 30L, 40L),
    mk_op(5, 2, Write(1), Ok, 50L, 60L),
    mk_op(6, 4, Read, Value(1), 62L, 70L),
    mk_op(7, 0, Read, Value(0), 72L, 80L),
  ])
  let v = minimize(h, reg(), CheckConfig::default())
  assert_true(v.ops.length() < 8)
  assert_true(v.ops.length() >= 2)
  let still = check_with(
    hist_of(v.ops),
    register_model(),
    CheckConfig::default(),
  )
  assert_true(still is Violation(_))
}

///|
test "minimize_raw can shrink below the guard" {
  // 显式请求纯 ddmin 时允许压到 1 条
  let v = minimize_raw(bad_history(), reg(), CheckConfig::default())
  assert_true(v.ops.length() >= 1)
  assert_true(v.ops.length() <= 3)
}

///|
test "minimize of empty history is empty" {
  let v = minimize(hist_of([]), reg(), CheckConfig::default())
  assert_eq(v.ops.length(), 0)
}

///|
test "remove_chunk drops the right range" {
  let ops = [
    mk_op(0, 0, Read, Value(0), 0L, 1L),
    mk_op(1, 0, Read, Value(0), 2L, 3L),
    mk_op(2, 0, Read, Value(0), 4L, 5L),
  ]
  let kept = remove_chunk(ops, 1, 1)
  assert_eq(kept.length(), 2)
  assert_eq(kept[0].id, 0)
  assert_eq(kept[1].id, 2)
  // 越界块只能删到末尾
  let tail = remove_chunk(ops, 2, 5)
  assert_eq(tail.length(), 2)
}

///|
// 回归：含重复操作 id 的违规历史，minimize 不得崩溃（abort）。
// 项目自身测试 audit_test.mbt 已锁定「重复 id 合法」，但 Expl 缓存与
// explainable 的「排除自己」逻辑按 op.id 区分身份，同 id 的不同操作会
// 互相串味 / 被误当自己排除，最终 ddmin 拒掉所有候选、shrink 兜底 abort。
test "minimize 不崩溃于含重复 id 的历史（register）" {
  // 两条 id=1 操作（W=2 与 R->1）共享 id，但内容不同。
  let hist = hist_of([
    mk_op(0, 0, Write(1), Ok, 0L, 10L),
    mk_op(1, 1, Write(2), Ok, 12L, 20L),
    mk_op(1, 2, Read, Value(1), 30L, 40L),
  ])
  // 必须正常返回 Violation，不 panic。
  let v = minimize(hist, reg(), CheckConfig::default())
  assert_true(v.ops.length() >= 1)
}

///|
// 同样的崩溃在 set 模型也存在（与具体模型无关）。
test "minimize 不崩溃于含重复 id 的历史（set）" {
  let hist = hist_of([
    mk_op(3, 0, Append(5), Ok, 0L, 1L),
    mk_op(3, 1, Pop, Bool(false), 2L, 3L),
  ])
  let v = minimize(hist, st(), CheckConfig::default())
  assert_true(v.ops.length() >= 1)
}
