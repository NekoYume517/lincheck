///|
// Independent boolean-set model and exhaustive permutation search. This does not
// call Model::apply, Model::accepts or the checker's min-end candidate rule.
fn set_reference_search(
  ops : Array[Operation],
  done : Array[Bool],
  members : Array[Bool],
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
    let next = members.copy()
    let valid = match op.kind {
      Write(v) | Append(v) =>
        if v >= 0 && v < 64 && op.result == Ok {
          next[v] = true
          true
        } else {
          false
        }
      Pop => {
        let mut smallest = -1
        for v, present in members {
          if present && smallest < 0 {
            smallest = v
          }
        }
        if smallest >= 0 {
          next[smallest] = false
        }
        op.result == Bool(smallest >= 0)
      }
      Read =>
        match op.result {
          Value(v) =>
            if v == -1 {
              let mut empty = true
              for present in members {
                if present {
                  empty = false
                }
              }
              empty
            } else {
              v >= 0 && v < 64 && members[v]
            }
          _ => false
        }
      Cas(_, _) => false
    }
    if valid {
      done[i] = true
      let ok = set_reference_search(ops, done, next, depth + 1)
      done[i] = false
      if ok {
        return true
      }
    }
  }
  false
}

///|
test "set membership: cached and uncached checks match independent boolean-set oracle" {
  for seed in 0..<200 {
    let h = generate_random(set_model(), GenConfig::new(2, 3, seed, 0.8))
    let reference = set_reference_search(
      h.operations,
      Array::make(h.length(), false),
      Array::make(64, false),
      0,
    )
    // 与 cross_reference_test 同款四档容量：1/3 会触发 cache_full 分支
    //（容量写满后不再写入、搜索继续），0 完全关闭，200000 正常容量。
    // set 模型此前只对拍 {0, 200000}，容量截断分支缺独立证据（2026-11-15 审计）。
    for max_states in [0, 1, 3, 200000] {
      let config = { ..CheckConfig::default(), time_budget_ms: 0, max_states, }
      let actual = check_with(h, set_model(), config)
      assert_eq(actual is Linearizable, reference)
    }
  }
}
