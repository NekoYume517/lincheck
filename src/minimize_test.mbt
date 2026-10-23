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

// ============================================================
// LC-1 回归：minimize 不得输出单操作退化解
// ============================================================
//
// 现象（旧实现，已实测复现）：
//   8 条 register 操作（含 Cas）的历史，check 的违规见证只有 1 条
//   ——`Cas(1->2) -> Bool(true)`，初值 0 上这个 CAS 不可能返回 true，
//   属于**历史数据自相矛盾**，不是并发竞态。
//   `minimize` 直接把这个 1 条操作的种子当见证输出（8 → 1），
//   同时绕过了 MIN_WITNESS 下界与可解释性守卫。
//
// 根因：`src/minimize.mbt` 的 `shrink` 兜底分支
//   `else if still_violates(seed, ...) { seed.copy() }`
//   完全不调用 `explainable()`，也不检查 `min_witness`——第 341 行算出的
//   `big_enough` 只在第一个分支用到。

///|
/// bugA 的形状：8 条 register 操作；min_end 是那条不可能的 CAS，
/// 于是 check 的搜索在 depth 0 就停住，见证只有 1 条操作。
/// 历史里另有一组**可解释的**真反例：
///   {W=7 [10,20], W=8 [22,30], R->7 [32,40]}
/// —— R 单独看相对初值 0 就违规，但 {R, W=7} 线性一致（写 7 后读到 7），
/// 而两次写不重叠迫使 R 必须读到 8。这才是要保留的 bug 语义。
fn bug_a_history() -> History {
  hist_of([
    mk_op(0, 0, Cas(1, 2), Bool(true), 2L, 5L),
    mk_op(1, 1, Write(7), Ok, 10L, 20L),
    mk_op(2, 2, Write(8), Ok, 22L, 30L),
    mk_op(3, 3, Read, Value(7), 32L, 40L),
    mk_op(4, 0, Read, Value(9), 42L, 50L),
    mk_op(5, 1, Cas(2, 3), Bool(true), 50L, 55L),
    mk_op(6, 2, Read, Value(4), 56L, 60L),
    mk_op(7, 3, Write(0), Ok, 60L, 70L),
  ])
}

///|
test "minimize 拒绝单操作退化解（bugA 8 → 1 回归）" {
  let h = bug_a_history()
  // 前提：check 给出的种子确实只有 1 条操作（旧实现正是被它带偏的）
  match check_with(h, register_model(), CheckConfig::default()) {
    Violation(v) => assert_eq(v.ops.length(), 1)
    _ => inspect("<应当 Violation>", content="")
  }
  let v = minimize(h, reg(), CheckConfig::default())
  // 下界与可解释性都是硬约束，不是建议
  assert_true(v.ops.length() >= MIN_WITNESS)
  assert_true(
    explainable(v.ops, register_model(), CheckConfig::default(), Expl::new()),
  )
  // 见证本身必须仍然违规（不能靠砍掉肇事操作来「满足」守卫）
  let still = check_with(
    hist_of(v.ops),
    register_model(),
    CheckConfig::default(),
  )
  assert_true(still is Violation(_))
}

///|
/// 守卫性质：四模型下的「初始状态自相矛盾」历史。
///
/// 最小化产物必须**要么**满足「长度 >= MIN_WITNESS 且可解释 且仍违规」，
/// **要么**如实报告「找不到可解释的最小见证」（原样返回整份历史 + 说明），
/// 二者之外的任何输出（尤其是静默的单操作退化解）都是缺陷。
test "minimize 守卫性质：四模型都不输出退化解" {
  let cases : Array[(AnyModel, History)] = [
    (reg(), hist_of([mk_op(0, 0, Cas(1, 2), Bool(true), 2L, 5L)])),
    (Counter(counter_model()), hist_of([mk_op(0, 0, Read, Value(5), 0L, 10L)])),
    (st(), hist_of([mk_op(0, 0, Read, Value(3), 0L, 10L)])),
    (Queue(queue_model()), hist_of([mk_op(0, 0, Pop, Bool(true), 0L, 10L)])),
  ]
  for entry in cases {
    let (m, h) = entry
    // 前提：这些历史确实违规
    let outcome = check_with(h, m, CheckConfig::default())
    assert_true(outcome is Violation(_))
    let v = minimize(h, m, CheckConfig::default())
    if v.ops.length() == 0 {
      inspect("<违规历史不应返回空见证>", content="")
    } else if v.explanation.contains("可解释") {
      // 如实报告分支：必须原样返回整份历史，且它仍然违规
      assert_eq(v.ops.length(), h.length())
      let still = check_with(hist_of(v.ops), m, CheckConfig::default())
      assert_true(still is Violation(_))
    } else {
      assert_true(v.ops.length() >= MIN_WITNESS)
      assert_true(explainable(v.ops, m, CheckConfig::default(), Expl::new()))
      let still = check_with(hist_of(v.ops), m, CheckConfig::default())
      assert_true(still is Violation(_))
    }
  }
}

///|
/// 新增可空入口：确实没有合格见证时必须返回 None，
/// 同时 `minimize` 必须原样返回整份历史并如实说明（不伪装成最小反例）。
test "minimize_witness 无可解释见证时返回 None" {
  let h = hist_of([mk_op(0, 0, Cas(1, 2), Bool(true), 2L, 5L)])
  match minimize_witness(h, reg(), CheckConfig::default()) {
    None => ()
    Some(_) => inspect("<期望 None>", content="")
  }
  let v = minimize(h, reg(), CheckConfig::default())
  assert_eq(v.ops.length(), h.length())
  assert_true(v.explanation.contains("可解释"))
  // 无论如何都必须仍然违规：不许靠「返回空/一致子集」蒙混过关
  assert_true(
    check_with(hist_of(v.ops), register_model(), CheckConfig::default())
    is Violation(_),
  )
}

///|
/// 守卫性质（四模型 × 多 seed）：只要最小见证存在，它就必须同时满足
/// 「长度 >= MIN_WITNESS、仍可复现违规、可解释」；不存在就返回 None。
/// 这条性质与具体模型无关——四种模型都必须成立。
test "minimal_witness 守卫性质：四模型 × 多 seed" {
  let models : Array[AnyModel] = [
    reg(),
    Counter(counter_model()),
    st(),
    Queue(queue_model()),
  ]
  for m in models {
    for seed in [1, 2, 3, 7, 11] {
      let cfg = GenConfig::{
        processes: 3,
        ops_per_process: 4,
        seed,
        concurrency: 0.5,
      }
      let histories = [
        generate_random(m, cfg),
        inject_violation(generate_consistent(m, cfg), m, seed),
      ]
      for h in histories {
        match check_with(h, m, CheckConfig::default()) {
          Violation(v) =>
            match
              minimal_witness(
                v.ops,
                h.operations,
                m,
                CheckConfig::default(),
                MIN_WITNESS,
                Expl::new(),
              ) {
              Some(w) => {
                assert_true(w.length() >= MIN_WITNESS)
                assert_true(
                  check_with(hist_of(w), m, CheckConfig::default())
                  is Violation(_),
                )
                assert_true(
                  explainable(w, m, CheckConfig::default(), Expl::new()),
                )
              }
              None => ()
            }
          _ => ()
        }
      }
    }
  }
}
