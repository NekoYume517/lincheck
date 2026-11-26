// ============================================================================
// lc41_wgl_wide_crossref_test.mbt —— 把 WGL 与独立参考的对拍**扩大规模**（LC-41）
//
// ## 为什么这一轮要扩
//
// `cross_reference_test.mbt` / `set_reference_test.mbt` 里的参考实现是真正
// 独立的（不调用 `Model::apply`，也不用 WGL 的 min-end 候选规则），但**规模
// 很小**：3 个操作、2 个进程。而 WGL 的两条剪枝恰恰在**规模**上才可能暴露：
//
// - 候选条件 `op.start <= min_end`（min_end 取自**全部**未线性化操作）；
// - 缓存键 `(状态, 剩余集合)` 的失败记忆。
//
// 小历史里这两条几乎不剪枝，剪错了也看不出来。
//
// ## 本文件覆盖的判据
//
// 1. **规模**：4 / 5 / 6 个操作、2~3 个进程，随机时间戳（含**相同**时间戳）；
// 2. **只读事务读到自己写的值**：同一进程内 write 后紧跟 read，读到自己写的值
//    是合法的（同进程顺序由 `end < start` 保证）；
// 3. **process 内顺序**：同进程相邻操作 `a.end <= b.start`；
// 4. **跨 process 并发**：区间重叠即并发，任意顺序都允许；
// 5. **时间戳相同**：`a.end == b.start` 不算 happens-before（只有严格 `<`）；
// 6. **时间戳为负 / 极大**：Int64 两头，不能被减法溢出搞成假并发或假顺序；
// 7. **缓存**：`max_states` 取 0 / 1 / 3 / 200000 四档，结果必须一致。
//
// 参考实现直接枚举全排列（6 个操作 = 720 种），完全不复用被检查的那套逻辑。
// ============================================================================

///|
fn lc41_op(
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
/// **独立参考**：枚举全部排列，逐条判断「此刻它前面的都已完成」并且模型接受。
///
/// 与 `cross_reference_test.mbt` 同思路，但**不复用**它的实现：这里用
/// 显式 `used` 位表 + 手写 register 语义，且 happens-before 判据写成
/// `before.end < op.start`（严格小于 —— 相等不是先后）。
fn lc41_ref_linearizable(ops : Array[Operation]) -> Bool {
  let n = ops.length()
  let used : Array[Bool] = Array::make(n, false)
  lc41_ref_go(ops, used, 0, 0)
}

///|
fn lc41_ref_go(
  ops : Array[Operation],
  used : Array[Bool],
  depth : Int32,
  state : Int32,
) -> Bool {
  if depth == ops.length() {
    return true
  }
  for i, op in ops {
    if used[i] {
      continue
    }
    // happens-before：还有**未使用**的操作在本操作开始前就结束了 → 不能选它
    let mut blocked = false
    for j, other in ops {
      if !used[j] && other.end < op.start {
        blocked = true
      }
    }
    if blocked {
      continue
    }
    // register 语义（手写，不调 Model::apply）
    let next = match op.kind {
      Write(v) => if op.result is Ok { Some(v) } else { None }
      Read =>
        if op.result is Value(x) && x == state {
          Some(state)
        } else {
          None
        }
      Cas(e, nw) =>
        if op.result is Bool(b) {
          if state == e {
            if b {
              Some(nw)
            } else {
              None
            }
          } else if !b {
            Some(state)
          } else {
            None
          }
        } else {
          None
        }
      _ => None
    }
    match next {
      Some(ns) => {
        used[i] = true
        if lc41_ref_go(ops, used, depth + 1, ns) {
          return true
        }
        used[i] = false
      }
      None => ()
    }
  }
  false
}

///|
/// **判据一**：WGL 与全排列参考在 5 个操作、含相同时间戳、含负/极大时间戳的
/// 一批手写历史上逐个一致。
///
/// 这些历史是按「容易让剪枝出错」的形状挑的，不是随机撒：
/// - 两个操作 `end` 完全相同（参考里必须按 `<` 而不是 `<=` 判先后）；
/// - 一个操作 `start == end`（零长区间）；
/// - 时间戳跨 0（负 → 正）；
/// - 时间戳贴 Int64 两端；
/// - 同进程 write→read 读到自己写的值（合法）；
/// - 同进程 read→read 读到同一个值（合法，中间没有别的写）。
test "LC-41: 相同时间戳/负值/极值/同进程读写 与全排列参考一致" {
  let m : AnyModel = Register(register_model())
  let cases : Array[Array[Operation]] = [
    // 1) end 完全相同 —— 只有严格 < 才是 happens-before
    [
      lc41_op(0, 0, Write(1), Ok, 0L, 10L),
      lc41_op(1, 1, Read, Value(1), 10L, 20L),
    ],
    // 2) 零长区间
    [lc41_op(0, 0, Write(1), Ok, 5L, 5L), lc41_op(1, 1, Read, Value(1), 5L, 5L)],
    // 3) 跨 0
    [
      lc41_op(0, 0, Write(1), Ok, -10L, -5L),
      lc41_op(1, 1, Read, Value(1), -5L, 5L),
    ],
    // 4) Int64 两端全并发
    [
      lc41_op(0, 0, Write(1), Ok, -9223372036854775808L, 9223372036854775807L),
      lc41_op(1, 1, Read, Value(0), -9223372036854775808L, 9223372036854775807L),
    ],
    // 5) 同进程 write 后 read 读到自己的值
    [lc41_op(0, 0, Write(7), Ok, 0L, 5L), lc41_op(1, 0, Read, Value(7), 5L, 9L)],
    // 6) 同进程 read→read 读到同一个值
    [
      lc41_op(0, 0, Read, Value(0), 0L, 5L),
      lc41_op(1, 0, Read, Value(0), 5L, 9L),
    ],
    // 7) 三操作：写、写、读中间值（违规）
    [
      lc41_op(0, 0, Write(1), Ok, 0L, 10L),
      lc41_op(1, 1, Write(2), Ok, 11L, 20L),
      lc41_op(2, 2, Read, Value(1), 21L, 30L),
    ],
    // 8) 三操作：局部序（同进程串联）
    [
      lc41_op(0, 0, Write(1), Ok, 0L, 4L),
      lc41_op(1, 0, Write(2), Ok, 4L, 8L),
      lc41_op(2, 1, Read, Value(2), 9L, 12L),
    ],
    // 9) CAS 链
    [
      lc41_op(0, 0, Write(1), Ok, 0L, 4L),
      lc41_op(1, 1, Cas(1, 5), Bool(true), 4L, 8L),
      lc41_op(2, 2, Read, Value(5), 8L, 12L),
    ],
    // 10) 全并发四操作
    [
      lc41_op(0, 0, Write(1), Ok, 0L, 100L),
      lc41_op(1, 1, Write(2), Ok, 0L, 100L),
      lc41_op(2, 2, Read, Value(1), 0L, 100L),
      lc41_op(3, 3, Read, Value(2), 0L, 100L),
    ],
    // 11) 五操作，混合并发
    [
      lc41_op(0, 0, Write(1), Ok, 0L, 10L),
      lc41_op(1, 1, Write(2), Ok, 5L, 15L),
      lc41_op(2, 2, Read, Value(2), 12L, 20L),
      lc41_op(3, 0, Read, Value(1), 11L, 21L),
      lc41_op(4, 1, Cas(1, 3), Bool(true), 22L, 30L),
    ],
  ]
  for k, ops in cases {
    let expected = lc41_ref_linearizable(ops)
    // 四档缓存容量都必须与参考一致
    for max_states in [0, 1, 3, 200000] {
      let config = { ..CheckConfig::default(), time_budget_ms: 0, max_states, }
      let actual = check_with({ operations: ops, }, m, config)
      if !(actual is Linearizable) == expected {
        println(
          "LC-41: case \{k} max_states=\{max_states} 参考=\{expected} 实际=\{(actual is Linearizable)}",
        )
        assert_true(false)
      }
    }
  }
}

///|
/// **判据二**：随机生成的 6 操作历史（3 进程 × 2 操作）也与全排列参考一致。
///
/// 3 进程 × 2 操作是既有对拍测试（`cross_reference_test.mbt` 用 2×3、
/// `set_reference_test.mbt` 用 3×3）覆盖不到的规模：6 个操作 = 720 种排列，
/// WGL 的 min-end 剪枝在这里才开始真正起限制作用。
///
/// 用固定 seed 保证确定性（`generate_random` 是自带 LCG，不碰 `@env.rand`）。
test "LC-41: 6 操作随机历史与全排列参考一致" {
  let m : AnyModel = Register(register_model())
  let cfg = { ..CheckConfig::default(), time_budget_ms: 0, }
  for seed in 0..<40 {
    let h = generate_random(register_model(), GenConfig::new(3, 2, seed, 0.8))
    let expected = lc41_ref_linearizable(h.operations)
    let actual = check_with(h, m, cfg)
    if !(actual is Linearizable) == expected {
      println(
        "LC-41: random seed=\{seed} 参考=\{expected} 实际=\{(actual is Linearizable)}",
      )
      assert_true(false)
    }
  }
}
