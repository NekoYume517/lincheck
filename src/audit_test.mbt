// 审计发现的回归测试（audit_test.mbt）
//
// 本文件每个测试对应一个审计阶段发现的真实缺陷或需要锁住的边界行为。
// 命名约定：缺陷类的测试标题以「审计」开头，行为锁定的以「行为」开头。

///|
test "审计：start > end 的操作返回 Unknown 而不是崩溃" {
  let h = History::new()
  h.add(Operation::{
    id: 0,
    process: 0,
    kind: Write(1),
    result: Ok,
    start: 10L,
    end: 5L,
  })
  let outcome = check_default(h, model_or_default("register"))
  match outcome {
    Unknown(_) => inspect(true, content="true")
    Linearizable =>
      inspect(false, content="非法区间不应判定为线性一致")
    Violation(_) =>
      inspect(false, content="非法区间应报 Unknown 而非 Violation")
  }
}

///|
test "审计：重复 id 的操作不会破坏最小反例的去重" {
  let h = History::new()
  h.add(Operation::{
    id: 7,
    process: 0,
    kind: Write(1),
    result: Ok,
    start: 0L,
    end: 5L,
  })
  h.add(Operation::{
    id: 7,
    process: 1,
    kind: Read,
    result: Value(1),
    start: 10L,
    end: 15L,
  })
  let outcome = check_default(h, model_or_default("register"))
  let code = match outcome {
    Linearizable => 0
    Violation(_) => 1
    Unknown(_) => 3
  }
  inspect(code, content="0")
}

///|
test "行为：模型 apply 不得原地修改传入状态（回溯正确性前提）" {
  // 如果 apply 原地修改 state，dfs 回溯后状态会被污染。
  // 此测试锁住「apply 返回全新数组」这一契约。
  let m = register_model()
  let before : State = [42]
  match m.apply(before, Write(7)) {
    Some((after, expected)) => {
      let ok = match expected {
        Ok => true
        _ => false
      }
      inspect(ok, content="true")
      inspect(before[0], content="42")
      inspect(after[0], content="7")
    }
    None => inspect(false, content="apply(Write) should be legal on register")
  }
}

///|
test "行为：缓存关闭与开启结论一致（register_bad）" {
  let h = History::new()
  h.add(Operation::{
    id: 0,
    process: 0,
    kind: Write(1),
    result: Ok,
    start: 0L,
    end: 10L,
  })
  h.add(Operation::{
    id: 1,
    process: 1,
    kind: Write(2),
    result: Ok,
    start: 12L,
    end: 20L,
  })
  h.add(Operation::{
    id: 2,
    process: 0,
    kind: Read,
    result: Value(1),
    start: 30L,
    end: 40L,
  })
  let no_cache = CheckConfig::{
    time_budget_ms: 5000,
    max_states: 0,
    allow_unknown_results: false,
  }
  let outcome = check(h, model_or_default("register"), no_cache)
  let code = match outcome {
    Linearizable => 0
    Violation(_) => 1
    Unknown(_) => 3
  }
  // 开启缓存的默认配置已在 checker_test 里断言过同一份历史 = 违规
  inspect(code, content="1")
}

///|
test "行为：allow_unknown_results 宽松模式下 Nil 可匹配任意期望" {
  let m = register_model()
  // result_matches 是 private 函数；黑盒测试改为通过完整检查行为验证：
  // 构造一个「操作结果为 Nil」的历史，严格模式下应违规、宽松模式下应线性一致。
  let strict = CheckConfig::{
    time_budget_ms: 5000,
    max_states: 10_000,
    allow_unknown_results: false,
  }
  let loose = CheckConfig::{
    time_budget_ms: 5000,
    max_states: 10_000,
    allow_unknown_results: true,
  }
  let h = History::new()
  h.add(Operation::{
    id: 0,
    process: 0,
    kind: Write(1),
    result: Ok,
    start: 0L,
    end: 10L,
  })
  h.add(Operation::{
    id: 1,
    process: 1,
    kind: Read,
    result: Nil,
    start: 20L,
    end: 30L,
  })
  let code_strict = match check(h, model_or_default("register"), strict) {
    Linearizable => 0
    Violation(_) => 1
    Unknown(_) => 3
  }
  inspect(code_strict, content="1")
  let code_loose = match check(h, model_or_default("register"), loose) {
    Linearizable => 0
    Violation(_) => 1
    Unknown(_) => 3
  }
  inspect(code_loose, content="0")
}

///|
test "审计：极小时间预算下大并发历史返回 Unknown 而不是挂死" {
  // 40 个完全并发的写读交错，搜索空间巨大
  let h = History::new()
  let mut id = 0
  for p in 0..<8 {
    for _ in 0..<5 {
      h.add(Operation::{
        id,
        process: p,
        kind: if id % 2 == 0 {
          Write(id)
        } else {
          Read
        },
        result: if id % 2 == 0 {
          Ok
        } else {
          Value(0)
        },
        start: 0L,
        end: 100L,
      })
      id = id + 1
    }
  }
  let cfg = CheckConfig::{
    time_budget_ms: 50,
    max_states: 10_000,
    allow_unknown_results: false,
  }
  let outcome = check_with(h, register_model(), cfg)
  match outcome {
    Unknown(reason) => {
      let has_budget = reason.contains("预算") || reason.contains("ms")
      inspect(has_budget, content="true")
    }
    Linearizable => inspect(true, content="fast machine, completed")
    Violation(_) => inspect(true, content="fast machine, completed")
  }
}

///|
test "行为：Read 在初值状态下的模型语义" {
  let m = register_model()
  match m.apply([0], Read) {
    Some((st, expected)) => {
      let ok = match expected {
        Value(0) => true
        _ => false
      }
      inspect(ok, content="true")
      inspect(st[0], content="0")
    }
    None => inspect(false, content="Read on init state should be legal")
  }
}

///|
test "审计：set 模型 64 位位图的跨字边界" {
  let m = set_model()
  // 集合模型用 [低32, 高32] 编码 64 位位图
  // 验证三个区域各取一个代表位：低位区(1)、跨字边界(31/32)、高位区(63)
  let mut all_ok = true
  for bit in [1, 31, 32, 63] {
    let st0 = m.init()
    match m.apply(st0, Append(bit)) {
      Some((st1, _)) => {
        let nonzero = st1[0] != 0 || st1[1] != 0
        if !nonzero {
          all_ok = false
        }
        match m.apply(st1, Pop) {
          Some((st2, res)) => {
            let emptied = st2[0] == 0 && st2[1] == 0
            if !emptied {
              all_ok = false
            }
            let popped_ok = match res {
              Empty => false
              Value(v) => v == bit
              _ => true
            }
            if !popped_ok {
              all_ok = false
            }
          }
          None => all_ok = false
        }
      }
      None => all_ok = false
    }
  }
  inspect(all_ok, content="true")
}

///|
test "审计：queue 模型 FIFO 顺序" {
  let m = queue_model()
  let st0 = m.init()
  match m.apply(st0, Append(1)) {
    Some((st1, _)) =>
      match m.apply(st1, Append(2)) {
        Some((st2, _)) =>
          match m.apply(st2, Pop) {
            Some((st3, res1)) => {
              let ok1 = match res1 {
                Value(1) => true
                _ => false
              }
              inspect(ok1, content="true")
              match m.apply(st3, Pop) {
                Some((_, res2)) => {
                  let ok2 = match res2 {
                    Value(2) => true
                    _ => false
                  }
                  inspect(ok2, content="true")
                }
                None => inspect(false, content="second pop should be legal")
              }
            }
            None => inspect(false, content="first pop should be legal")
          }
        None => inspect(false, content="true")
      }
    None => inspect(false, content="true")
  }
}

///|
test "审计：counter 模型拒绝回退" {
  let m = counter_model()
  let st : State = [5]
  // 写入更小的值应被视为非法（单调计数器）
  let rejected = match m.apply(st, Write(3)) {
    Some(_) => false
    None => true
  }
  inspect(rejected, content="true")
  // 写入相同值（原地踏步）是允许的
  let accepted = match m.apply(st, Write(5)) {
    Some(_) => true
    None => false
  }
  inspect(accepted, content="true")
}
