// ============================================================================
// generate.mbt — 并发历史生成器（元测试用）
//
// 确定性是硬性要求：同一 seed 必须产出逐字节相同的历史。所以随机数一律
// 走自带的 LCG，绝不调用 @env.rand / @random。
//
// generate_consistent 的可线性化保证：
//   1. 先在一个单一全序下依次执行 N 个操作，把每步真实的 (kind, result) 记下来
//      —— 这个全序本身就是一份合法线性化。
//   2. 给每个操作分配互不重叠、单调递增的初始时间区间。
//   3. 只「拉宽」区间：把 end 往后推、把 start 往前拉。
//      拉宽永远不会让「原本在前」的操作变成「在后」：
//      设 a 原本在 b 之前（a.end < b.start），我们的操作从不把 a.start 往后移、
//      也从不把 b.end 往前移，因此 b.end < a.start 永远不可能成立。
//      于是原来的全序依然满足实时约束，仍然是合法线性化。
// ============================================================================

///|
/// 线性同余随机数发生器（Numerical Recipes 常数）
pub(all) struct Rng {
  mut state : Int32
}

///|
pub fn Rng::new(seed : Int32) -> Rng {
  // 保证非零初值，避免退化
  { state: if seed == 0 { 1 } else { seed & 0x7FFFFFFF }, }
}

///|
pub fn Rng::next(self : Rng) -> Int32 {
  self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
  self.state
}

///|
/// [0, n) 均匀整数；n <= 0 时返回 0
pub fn Rng::below(self : Rng, n : Int32) -> Int32 {
  if n <= 0 {
    0
  } else {
    let v = self.next()
    v % n
  }
}

///|
/// [0.0, 1.0) 均匀浮点
pub fn Rng::unit(self : Rng) -> Double {
  let v = self.next()
  (v % 1000000).to_double() / 1000000.0
}

///|
/// 以概率 p 命中
pub fn Rng::chance(self : Rng, p : Double) -> Bool {
  self.unit() < p
}

///|
pub(all) struct GenConfig {
  processes : Int32
  ops_per_process : Int32
  seed : Int32
  concurrency : Double
}

///|
pub fn GenConfig::default() -> GenConfig {
  { processes: 3, ops_per_process: 4, seed: 42, concurrency: 0.5, }
}

///|
pub fn GenConfig::new(
  processes : Int32,
  ops_per_process : Int32,
  seed : Int32,
  concurrency : Double,
) -> GenConfig {
  { processes, ops_per_process, seed, concurrency, }
}

///|
/// 生成器能考虑的全部操作种类（模型自会筛掉不合法者）
fn kind_pool() -> Array[OpKind] {
  [
    Write(1),
    Write(2),
    Write(3),
    Write(0),
    Read,
    Cas(0, 1),
    Cas(1, 2),
    Cas(2, 3),
    Append(1),
    Append(2),
    Append(3),
    Pop,
  ]
}

///|
/// 在当前状态下挑一个模型允许的操作种类
///
/// 返回 None 说明该模型下当前状态已无合法操作（例如队列空了只剩 Pop 之外的选择）。
fn[M : Model] pick_legal(
  model : M,
  state : State,
  rng : Rng,
) -> (OpKind, OpResult)? {
  let pool = kind_pool()
  // 收集合法候选，保证选择只依赖 (state, 随机序列)
  let legal : Array[(OpKind, OpResult)] = []
  for k in pool {
    match model.apply(state, k) {
      Some((_, expected)) => legal.push((k, expected))
      None => ()
    }
  }
  if legal.length() == 0 {
    return None
  }
  let idx = rng.below(legal.length())
  Some(legal[idx])
}

///|
/// 生成一个「保证线性一致」的历史：先在单一全序下执行，再随机拉宽时间区间
pub fn[M : Model] generate_consistent(model : M, config : GenConfig) -> History {
  let processes = if config.processes < 1 { 1 } else { config.processes }
  let per_proc = if config.ops_per_process < 0 {
    0
  } else {
    config.ops_per_process
  }
  let concurrency = if config.concurrency < 0.0 {
    0.0
  } else if config.concurrency > 1.0 {
    1.0
  } else {
    config.concurrency
  }
  let total = processes * per_proc

  // —— 第 1 步：单一全序下依次执行 ——
  let rng = Rng::new(config.seed)
  let kinds : Array[OpKind] = []
  let results : Array[OpResult] = []
  let mut state = model.init()
  let mut i = 0
  while i < total {
    match pick_legal(model, state, rng) {
      Some((k, expected)) =>
        match model.apply(state, k) {
          Some((next, _)) => {
            kinds.push(k)
            results.push(expected)
            state = next
          }
          None => ()
        }
      None =>
        // 死路：跳过这一步（少见，仅模型自定义时才会发生）
        i = total
    }
    i = i + 1
  }
  let n = kinds.length()

  // —— 第 2 步：互不重叠的单调递增区间 ——
  let starts : Array[Int64] = []
  let ends : Array[Int64] = []
  let mut t : Int64 = 0L
  let mut j = 0
  while j < n {
    starts.push(t)
    ends.push(t + 2L)
    t = t + 3L
    j = j + 1
  }

  // —— 第 3 步：只拉宽（end 往后、start 往前），不破坏原有全序 ——
  let mut k = 0
  while k < n {
    if rng.chance(concurrency) {
      // 3a. 把 end 往后推，制造与后继的重叠
      let widen = 1L + rng.below(4).to_int64()
      let limit = if k + 1 < n { ends[k + 1] } else { ends[k] + 4L }
      let target = ends[k] + widen
      ends[k] = if target > limit { limit } else { target }
    }
    if rng.chance(concurrency) && k > 0 {
      // 3b. 把 start 往前拉，制造与前驱的重叠
      let widen = 1L + rng.below(4).to_int64()
      let floor = starts[k - 1]
      let target = starts[k] - widen
      starts[k] = if target < floor { floor } else { target }
    }
    k = k + 1
  }

  // —— 组装 ——
  let history = History::new()
  let mut m = 0
  while m < n {
    history.add(Operation::{
      id: m,
      process: m % processes,
      kind: kinds[m],
      result: results[m],
      start: starts[m],
      end: ends[m],
    })
    m = m + 1
  }
  history
}

///|
/// 生成随机历史（可能是非线性的，用于测试检查器能发现问题）
///
/// 与 generate_consistent 的区别：结果值是随便掷的，不看模型能返回什么。
pub fn[M : Model] generate_random(model : M, config : GenConfig) -> History {
  let processes = if config.processes < 1 { 1 } else { config.processes }
  let per_proc = if config.ops_per_process < 0 {
    0
  } else {
    config.ops_per_process
  }
  let concurrency = if config.concurrency < 0.0 {
    0.0
  } else if config.concurrency > 1.0 {
    1.0
  } else {
    config.concurrency
  }
  let total = processes * per_proc
  let rng = Rng::new(config.seed * 7 + 13)
  // 只用来校验模型是否认得该 kind（不看返回值）
  let probe_state = model.init()

  let pool = kind_pool()
  let history = History::new()
  let mut i = 0
  while i < total {
    // 选一个模型认得的 kind（否则检查器直接剪枝，历史会平凡合法）
    let start_idx = rng.below(pool.length())
    let mut picked : OpKind? = None
    let mut attempt = 0
    while picked is None && attempt < pool.length() {
      let k = pool[(start_idx + attempt) % pool.length()]
      match model.apply(probe_state, k) {
        Some(_) => picked = Some(k)
        None => ()
      }
      attempt = attempt + 1
    }
    match picked {
      None => i = total
      Some(k) => {
        // 随机起点；并发度越高，区间越长、越容易重叠
        let base = (i * 3).to_int64()
        let span : Int64 = 1L +
          rng.below(3 + (concurrency * 10.0).to_int()).to_int64()
        let start_t = base + rng.below(3).to_int64()
        let end_t = start_t + span
        history.add(Operation::{
          id: i,
          process: rng.below(processes),
          kind: k,
          result: random_result(k, rng),
          start: start_t,
          end: end_t,
        })
      }
    }
    i = i + 1
  }
  history
}

///|
/// 按 kind 掷一个「形状正确但值随机」的结果
fn random_result(kind : OpKind, rng : Rng) -> OpResult {
  match kind {
    Write(_) => Ok
    Read => Value(rng.below(4))
    Cas(_, _) => Bool(rng.below(2) == 0)
    Append(_) => Ok
    Pop => if rng.below(2) == 0 { Empty } else { Value(rng.below(4)) }
  }
}

///|
/// 一种 kind 能容忍的结果候选（用于注入时穷举试探）
fn result_candidates() -> Array[OpResult] {
  [Ok, Value(0), Value(1), Value(2), Value(3), Bool(true), Bool(false), Empty]
}

///|
/// 在合法历史里注入一个错误，制造确定的违规
///
/// 做法：按 seed 决定一个轮转起点，依次挑操作、依次试各种「错误结果」，
/// 每改一次就用检查器实测；第一个真的变违规的就采用。
/// 这样不依赖具体模型的返回值域，也不会因为改完仍合法而悄悄失效。
pub fn inject_violation(
  history : History,
  model : AnyModel,
  seed : Int32,
) -> History {
  let ops = history.operations
  let n = ops.length()
  if n == 0 {
    return history
  }
  let config = CheckConfig::default()
  let rng = Rng::new(seed * 31 + 7)
  let offset = rng.below(n)
  let candidates = result_candidates()
  let mut i = 0
  while i < n {
    let idx = (offset + i) % n
    let original = ops[idx]
    let mut c = 0
    while c < candidates.length() {
      let trial = candidates[c]
      if !OpResult::equal(trial, original.result) {
        // 造一份改过单个操作的副本
        let mutated = History::new()
        let mut j = 0
        while j < n {
          if j == idx {
            mutated.add(Operation::{
              id: original.id,
              process: original.process,
              kind: original.kind,
              result: trial,
              start: original.start,
              end: original.end,
            })
          } else {
            mutated.add(ops[j])
          }
          j = j + 1
        }
        match check(mutated, model, config) {
          Violation(_) =>
            // 命中：这个改动确定破坏线性一致性
            return mutated
          _ => ()
        }
      }
      c = c + 1
    }
    i = i + 1
  }
  // 所有单点改动都能被吸收（例如历史里全是并发写、返回值随便都行）：原样返回
  history
}
