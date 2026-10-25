// cross_reference_test.mbt — 独立暴力参考模型（register/counter/queue）与 WGL 检查器对拍。
//
// 与 set_reference_test.mbt 同一思路：参考实现完全不调用 Model::apply、
// Model::accepts 或 WGL 的 min-end 候选规则，用「逐操作尝试 + happens-before
// 剪枝」的朴素搜索独立判定可线性化性。缓存关闭 (max_states=0)、极小
// (1/3，会触发 cache_full) 与正常 (200000) 四种配置都必须与参考一致，
// 验证缓存与容量截断不改变语义。另附注入违规 × minimize 的守卫回归：
// 每个最小见证必须 ≥2 条操作且复检仍违规。

///|
fn reg_ref_apply(state : Int32, kind : OpKind, result : OpResult) -> Int32? {
  match kind {
    Write(v) => if result == Ok { Some(v) } else { None }
    Read => if result is Value(x) && x == state { Some(state) } else { None }
    Cas(e, n) =>
      if state == e && result == Bool(true) {
        Some(n)
      } else if state != e && result == Bool(false) {
        Some(state)
      } else {
        None
      }
    _ => None
  }
}

///|
fn cnt_ref_apply(state : Int32, kind : OpKind, result : OpResult) -> Int32? {
  match kind {
    Write(v) => if v >= state && result == Ok { Some(v) } else { None }
    Read => if result is Value(x) && x == state { Some(state) } else { None }
    _ => None
  }
}

///|
fn queue_ref_apply(
  q : Array[Int32],
  kind : OpKind,
  result : OpResult,
) -> Array[Int32]? {
  match kind {
    Append(v) =>
      if result == Ok {
        let nq = q.copy()
        nq.push(v)
        Some(nq)
      } else {
        None
      }
    Pop =>
      if q.length() == 0 {
        if result == Empty {
          Some(q.copy())
        } else {
          None
        }
      } else if result is Value(f) && f == q[0] {
        let nq : Array[Int32] = []
        for i, x in q {
          if i > 0 {
            nq.push(x)
          }
        }
        Some(nq)
      } else {
        None
      }
    Read =>
      if q.length() == 0 {
        if result is Value(-1) {
          Some(q.copy())
        } else {
          None
        }
      } else if result is Value(x) && x == q[0] {
        Some(q.copy())
      } else {
        None
      }
    _ => None
  }
}

///|
fn ref_search(
  mode : String,
  ops : Array[Operation],
  done : Array[Bool],
  reg : Int32,
  q : Array[Int32],
  depth : Int32,
) -> Bool {
  if depth == ops.length() {
    return true
  }
  for i, op in ops {
    if done[i] {
      continue
    }
    let mut blocked = false
    for j, before in ops {
      if !done[j] && before.end < op.start {
        blocked = true
      }
    }
    if blocked {
      continue
    }
    if mode == "queue" {
      match queue_ref_apply(q, op.kind, op.result) {
        Some(nq) => {
          done[i] = true
          if ref_search(mode, ops, done, reg, nq, depth + 1) {
            return true
          }
          done[i] = false
        }
        None => ()
      }
    } else {
      let st = if mode == "counter" {
        cnt_ref_apply(reg, op.kind, op.result)
      } else {
        reg_ref_apply(reg, op.kind, op.result)
      }
      match st {
        Some(ns) => {
          done[i] = true
          if ref_search(mode, ops, done, ns, q, depth + 1) {
            return true
          }
          done[i] = false
        }
        None => ()
      }
    }
  }
  false
}

///|
fn cross_check(mode : String, model : AnyModel) -> Bool {
  let mut ok = true
  for seed in 0..<200 {
    let h = generate_random(model, GenConfig::new(2, 3, seed, 0.8))
    let reference = ref_search(
      mode,
      h.operations,
      Array::make(h.length(), false),
      0,
      [],
      0,
    )
    for max_states in [0, 1, 3, 200000] {
      let config = { ..CheckConfig::default(), time_budget_ms: 0, max_states, }
      let actual = check(h, model, config)
      let actual_lin = actual is Linearizable
      if actual_lin != reference {
        println(
          "MISMATCH mode=\{mode} seed=\{seed} max_states=\{max_states} ref=\{reference}",
        )
        ok = false
      }
    }
  }
  ok
}

///|
test "audit: register WGL vs brute force x200" {
  assert_true(cross_check("register", Register(register_model())))
}

///|
test "audit: counter WGL vs brute force x200" {
  assert_true(cross_check("counter", Counter(counter_model())))
}

///|
test "audit: queue WGL vs brute force x200" {
  assert_true(cross_check("queue", Queue(queue_model())))
}

///|
test "audit: injected violations stay violations and shrink keeps guards" {
  for seed in 0..<50 {
    let m : AnyModel = Register(register_model())
    let h = generate_consistent(m, GenConfig::new(3, 3, seed, 0.5))
    let bad = inject_violation(h, m, seed)
    if bad.to_jsonl() != h.to_jsonl() {
      if !(check_default(bad, m) is Violation(_)) {
        assert_true(false)
      }
      let v = minimize(bad, m, CheckConfig::default())
      // witness must still violate, be >=2 ops, and re-check as Violation
      if v.ops.length() < 2 {
        println("seed=\{seed} witness too small: \{v.ops.length()}")
        assert_true(false)
      }
      let wh : History = { operations: v.ops, }
      if !(check_default(wh, m) is Violation(_)) {
        println("seed=\{seed} witness no longer violates")
        assert_true(false)
      }
    }
  }
}
