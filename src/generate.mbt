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
  // 映射规则：seed=0 归一为 1；其余先 & 0x7FFFFFFF 掩掉符号位。
  // 注意 Int32::MIN（-2147483648）掩码后恰好为 0，并不满足「初值非零」——
  // 但 LCG 的首个 next() 即产出 12345（0 * a + c），序列立即回到正常轨道，
  // 没有退化：任何 seed 的序列都由 (state 初值, LCG 常数) 唯一确定，
  // 确定性不受影响（2026-11-15 审计 #6 实测 seed=Int32::MIN 两次 gen
  // 逐字节一致）。保留现状而不强行归一，避免改变既有种子的产物。
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
/// 钳制规模参数并算出**操作总数**（`processes × ops_per_process`）。
///
/// 返回 `None` = 乘积在 Int32 溢出，调用方必须报用法错误而不是继续跑。
///
/// 为什么必须显式检查：`processes` 与 `ops_per_process` 都是用户可控的
/// Int32，乘积在 Int32 回绕会得到一个**完全无关**的循环上界。最危险的一档是
/// `65536 × 65536` —— 数学乘积 `4294967296` 回绕成 `0`，于是生成器安静地
/// 产出一份空历史并以 exit 0 退出；调用方拿到 `{}` 与「成功」无法区分
/// （`gen` 之后 `check` 还会如实报告 `{"verdict":"linearizable","total":0}`）。
/// `65537 × 65536` 更隐蔽：回绕成 `65536`，会真的生成一份规模完全不对的历史。
///
/// 钳制规则与两个生成器原有的行为一致（`processes < 1 → 1`、
/// `ops_per_process < 0 → 0`），因此正常调用不受影响。
///
/// 用除法而不是乘法来判定溢出：`processes > MAX / per_proc` 在两边都是
/// 正数时与 `processes * per_proc > MAX` 等价，且自身不会溢出。

///|
/// 单次 `gen` 允许生成的操作总数上限（LC-A1，2026-11-10 审计）。
///
/// 为什么需要它：`total_ops_checked` 只防 Int32 回绕，`--processes
/// 2147483647 --ops 1` 的产品是 2147483647（不越界、不回绕），随后
/// `generate_consistent` 按这个规模分配 kinds/results/operations 三个
/// 数组——实测 90 秒不终止（需 ~150GB），既不是用法错误也不是数据
/// 错误，进程挂死、退出码掉出 0..4 契约。
///
/// 上限取 10,000,000：本项目定位是「工具级历史」——PLAN/API 里的旗舰
/// 例子是几千到几万操作，check 侧另有时间预算兜底；一千万条历史
/// （每条约 40–60 字节）已是数十 MB 量级，足够覆盖真实回归场景，
/// 又不至于让生成器在分配阶段就把机器拖死。
pub const MAX_GENERATED_OPS : Int32 = 10_000_000

///|
/// 判定「乘法不越界**且**规模在可行上限内」。超出返回 `None`，
/// CLI 据此报用法错误（exit 2）。
pub fn total_ops_checked(processes : Int32, ops_per_process : Int32) -> Int32? {
  let procs = if processes < 1 { 1 } else { processes }
  let per_proc = if ops_per_process < 0 { 0 } else { ops_per_process }
  if per_proc == 0 {
    return Some(0)
  }
  // Int32 上限 2147483647。procs > MAX / per_proc ⇒ 乘积越界。
  if procs > 2147483647 / per_proc {
    return None
  }
  let total = procs * per_proc
  // 能表示 ≠ 能生成：超过可行规模同样是「参数不可用」，如实拒绝。
  if total > MAX_GENERATED_OPS {
    return None
  }
  Some(total)
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
  // 溢出时退化成 0（与 `per_proc == 0` 的空历史一致），而不是回绕成一个
  // 毫无关系的上界。CLI 会在更外层用 `total_ops_checked` 先报用法错误，
  // 所以这条兜底只服务于直接调用库的调用方。
  let total = match total_ops_checked(processes, per_proc) {
    Some(n) => n
    None => 0
  }

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
  //
  // 拉宽还必须尊重**同一进程**的先后：一个客户端一次只能有一个在途操作，
  // 它的下一条要等上一条返回之后才开始。同进程的邻居下标相差 `processes`
  //（组装时 `process = m % processes`），所以：
  //   · processes >= 2 时这一对邻居比相邻操作更远，取 min/max 后**产物逐字节
  //     不变**（`generate_test` 的确定性断言 + 本文件的手工锚点都覆盖到）；
  //   · processes == 1 时它就是相邻操作，于是单客户端历史必然串行
  //     （2026-11-17 审计 LC-6：旧实现在这里能造出「同一 proc 两条在途操作」，
  //     物理上不可能，也让 selfcheck 的「合法历史」前提失效）。
  let step = processes
  let mut k = 0
  while k < n {
    if rng.chance(concurrency) {
      // 3a. 把 end 往后推，制造与后继的重叠
      let widen = 1L + rng.below(4).to_int64()
      let mut limit = if k + 1 < n { ends[k + 1] } else { ends[k] + 4L }
      if k + step < n {
        // 同进程后继开始前，本操作必须已返回：end <= 后继 start（相等 = 紧接，不算重叠）。
        let same_process_limit = starts[k + step]
        if same_process_limit < limit {
          limit = same_process_limit
        }
      }
      let target = ends[k] + widen
      ends[k] = if target > limit { limit } else { target }
    }
    if rng.chance(concurrency) && k > 0 {
      // 3b. 把 start 往前拉，制造与前驱的重叠
      let widen = 1L + rng.below(4).to_int64()
      let mut floor = starts[k - 1]
      if k >= step {
        // 同进程前驱返回之后本操作才可能开始：start >= 前驱 end（相等 = 紧接）。
        // （由 3a 的同一个上界可知 floor <= starts[k]，因此这里只会往左拉。）
        let same_process_floor = ends[k - step]
        if same_process_floor > floor {
          floor = same_process_floor
        }
      }
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
  // 同 generate_consistent：溢出不回绕，退化成空历史（CLI 层会先报用法错误）
  let total = match total_ops_checked(processes, per_proc) {
    Some(n) => n
    None => 0
  }
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
