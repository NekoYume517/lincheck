/// # 线性一致性检查器（checker.mbt）
///
/// 实现 **Wing-Gong-Lowe** 搜索算法 + **Lowe 2017** 的状态缓存。
///
/// ## 要解决的问题
///
/// 给定一段并发历史（每个操作有 `start`/`end` 区间，以及它声明的返回值），
/// 判断是否存在一个**全序**，使得：
///
/// 1. 全序尊重所有 happens-before 关系（`a.end < b.start` ⇒ a 排在 b 之前）
/// 2. 按全序逐个把操作应用到模型上时，模型给出的期望结果与历史记录完全一致
///
/// 暴力枚举 n! 种排列不可行，回溯搜索配上剪枝才是可行做法。
///
/// ## 候选条件（WGL 的核心剪枝）
///
/// 设 `remaining` 为所有尚未线性化的操作，`min_end = min(op.end for op in remaining)`。
///
/// > 操作 `op` 可以被**下一个**线性化，当且仅当 `op.start <= min_end`。
///
/// **为什么**：设 `q` 是 `end` 最小的那个操作。若 `op.start > q.end`，
/// 则 `q.end < op.start`，即 `q` happens-before `op`，`q` 必须排在 `op` 前面；
/// 而 `q` 尚未线性化，所以 `op` 不可能插到最前面。
/// 反之若 `op.start <= min_end`，则没有任何未线性化操作确定在 `op` 之前完成，
/// 把 `op` 提到最前不会违反任何 happens-before 约束。
///
/// 注意 `min_end` 取自**全部**未线性化操作，而不是候选自己的 end——这是最容易写错的一点。
///
/// ## 确定性
///
/// 候选按 `(start, id)` 升序尝试。排序保证同一输入永远产生同一搜索树，
/// 从而同一份历史两次运行得到完全相同的结论与解释（bug 可复现）。
///
/// ## Lowe 状态缓存
///
/// 搜索树中同一个 `(当前状态, 剩余操作集合)` 会被不同路径反复到达。
/// 一旦某次探索证明它**确定失败**，就记下来，下次直接返回。
/// 无缓存时复杂度是阶乘级；有缓存后上百个操作的真实历史通常毫秒级完成。
///
/// 键必须**精确编码** `(状态, 剩余集合)`，不能只用哈希值——哈希碰撞会让
/// 搜索错误地相信某个子问题已失败，直接导致漏报违规。这里把状态拼成
/// `[1,2]` 形式的字符串、把剩余集合拼成 `"1011"` 位串，二者拼接作为键。
///
/// 只缓存"确定失败"：成功会立即沿调用栈返回 `true`，无需缓存。
///
/// ## 未知是合法结论
///
/// 超出时间预算时返回 `Unknown`，既不挂死也不猜。生产历史可能几十万操作，
/// 硬撑只会让工具不可用。

///|
/// 检查结果。
pub(all) enum CheckOutcome {
  /// 线性一致：存在合法全序
  Linearizable
  /// 发现反例
  Violation(Violation)
  /// 超时/资源耗尽，结论未知
  Unknown(String)
} derive(Debug)

///|
/// 反例描述。
pub(all) struct Violation {
  /// 反例涉及的操作子集（按 id 升序）。
  ///
  /// 这里是"最长一致前缀 + 卡住的那个操作"，是判断所需的最小证据；
  /// 真正的 delta-debugging 最小化由 `minimize.mbt` 在其之上继续做。
  ops : Array[Operation]
  /// 搜索过程中最后一致的前缀长度
  depth : Int32
  /// 人类可读的解释
  explanation : String
} derive(Debug)

///|
/// 检查配置。
pub(all) struct CheckConfig {
  /// 时间预算（毫秒）。`<= 0` 表示不设上限。超时返回 `Unknown`。
  time_budget_ms : Int32
  /// 缓存条目上限。`<= 0` 表示完全关闭缓存（用于验证缓存不改变语义）。
  max_states : Int32
  /// 是否把历史里的 `Nil` 结果视为"可以是任意值"（宽松模式）。
  allow_unknown_results : Bool
} derive(Debug)

///|
/// 默认配置：5 秒预算、20 万条缓存、严格匹配结果。
pub fn CheckConfig::default() -> CheckConfig {
  { time_budget_ms: 5000, max_states: 200_000, allow_unknown_results: false, }
}

// ============================================================
// 搜索上下文
// ============================================================
//
// 这个结构体刻意**不带泛型参数**：MoonBit 的结构体不支持 `struct S[M : Model]` 这种
// 带 trait 约束的声明。泛型只出现在函数上（`fn[M : Model] dfs(...)`），
// 模型实例作为普通参数传递。这样既享受编译期单态化，又不必为上下文发明泛型包装。

///|
struct SearchState {
  /// 缓存：`状态编码|剩余位串` → true 表示该子问题已确定失败
  cache : Map[String, Bool]
  /// 访问的搜索节点数（每次 dfs 进入记 1）
  mut explored : Int32
  /// 缓存命中次数
  mut cache_hits : Int32
  /// 超时截止时刻（毫秒时间戳）；`no_deadline` 为 true 时忽略
  deadline : UInt64
  /// 是否不设时间上限
  no_deadline : Bool
  /// 是否已超时（一旦置位整个搜索作废）
  mut timed_out : Bool
  /// 缓存是否已满（满了就不再写入，搜索继续）
  mut cache_full : Bool
  /// 是否已经记录过任何进度（用于允许深度 0 的首次记录）
  mut recorded : Bool
  /// 已记录的最长一致前缀深度
  mut best_depth : Int32
  /// 该前缀的操作下标（按线性化顺序）
  mut best_prefix : Array[Int32]
  /// 该前缀结束时的模型状态
  mut best_state : State
  /// 在前缀末尾"能通过候选条件但结果不匹配"的操作下标；-1 表示没有
  mut best_fail : Int32
  /// 该操作被模型期望的结果（用于解释文本）
  mut best_fail_expected : OpResult
}

// ============================================================
// 小工具
// ============================================================

///|
/// 结果匹配规则。
///
/// 严格模式要求 `OpResult` 完全相等；宽松模式额外允许历史记录为 `Nil`
/// （结果未知）的操作匹配任意期望值——模拟"这次采样没拿到返回值"。
fn[M : Model] result_matches(
  model : M,
  state : State,
  kind : OpKind,
  expected : OpResult,
  actual : OpResult,
  allow_unknown : Bool,
) -> Bool {
  if actual is Nil {
    allow_unknown
  } else {
    model.accepts(state, kind, expected, actual)
  }
}

///|
/// 缓存键：状态编码 + 剩余操作位串。
///
/// 位串 `"1011"` 表示下标 0/2/3 已线性化、下标 1 尚未。
/// 两个分量都是**精确编码**，不依赖哈希，因此不存在碰撞导致的错误命中。
fn cache_key(state : State, remaining : Array[Bool]) -> String {
  let sb = StringBuilder()
  sb.write_string(state_to_string(state))
  sb.write_string("|")
  for r in remaining {
    if r {
      sb.write_char('1')
    } else {
      sb.write_char('0')
    }
  }
  sb.to_string()
}

///|
/// 在未线性化的操作里找最小的 `end`。返回 `(下标, end)`；没有剩余时返回 `(-1, 0L)`。
fn min_end_of(
  ops : Array[Operation],
  remaining : Array[Bool],
) -> (Int32, Int64) {
  let mut best_idx = -1
  let mut best_end : Int64 = 0L
  for i, alive in remaining {
    if alive {
      let e = ops[i].end
      if best_idx < 0 || e < best_end {
        best_idx = i
        best_end = e
      }
    }
  }
  (best_idx, best_end)
}

///|
/// 收集候选操作下标，按 `(start, id)` 升序排序保证确定性。
///
/// 条件：`op.start <= min_end`，其中 `min_end` 取自**所有**未线性化操作。
fn collect_candidates(
  ops : Array[Operation],
  remaining : Array[Bool],
  min_end : Int64,
) -> Array[Int32] {
  let candidates : Array[Int32] = []
  for i, alive in remaining {
    if alive && ops[i].start <= min_end {
      candidates.push(i)
    }
  }
  candidates.sort_by(fn(a, b) {
    let ds = ops[a].start - ops[b].start
    if ds < 0L {
      -1
    } else if ds > 0L {
      1
    } else {
      ops[a].id - ops[b].id
    }
  })
  candidates
}

///|
/// 超时轮询：每 256 个节点看一次时钟，避免 `now()` 本身成为瓶颈。
fn poll_deadline(ctx : SearchState) -> Unit {
  if !ctx.no_deadline && !ctx.timed_out && ctx.explored % 256 == 0 {
    if @env.now() >= ctx.deadline {
      ctx.timed_out = true
    }
  }
}

///|
/// 原子地记录"最深一致前缀 + 该处的失败点"。
///
/// **必须原子**：前缀和失败点来自同一条搜索路径，分开记录会让解释文本
/// 出现"前缀来自分支 A、失败原因来自分支 B"的错配。
///
/// 只在严格更深时覆盖（首次记录除外），因此记录下来的永远是搜索到的最深处。
fn record_progress(
  ctx : SearchState,
  depth : Int32,
  prefix : Array[Int32],
  state : State,
  fail_idx : Int32,
  fail_expected : OpResult,
) -> Unit {
  if !ctx.recorded || depth > ctx.best_depth {
    ctx.recorded = true
    ctx.best_depth = depth
    ctx.best_prefix = prefix.copy()
    ctx.best_state = state.copy()
    ctx.best_fail = fail_idx
    ctx.best_fail_expected = fail_expected
  }
}

// ============================================================
// 核心回溯搜索
// ============================================================

///|
/// 深度优先搜索一个合法线性化顺序。
///
/// 参数：
/// - `remaining[i] == true` 表示 `ops[i]` 还没被线性化
/// - `state`：已线性化的操作依次应用到模型后的状态
/// - `depth`：已线性化的操作个数
/// - `path`：已线性化的操作下标（按线性化顺序）
///
/// 返回 `true` = 找到合法全序；`false` = 确定失败**或**超时（由 `ctx.timed_out` 区分）。
fn[M : Model] dfs(
  ctx : SearchState,
  model : M,
  ops : Array[Operation],
  remaining : Array[Bool],
  state : State,
  depth : Int32,
  path : Array[Int32],
  config : CheckConfig,
) -> Bool {
  // ---- 0. 记账 + 超时检查 ----
  ctx.explored = ctx.explored + 1
  poll_deadline(ctx)
  if ctx.timed_out {
    return false
  }

  // ---- 1. 终止条件：所有操作都线性化完 → 找到合法全序 ----
  let total = ops.length()
  if depth == total {
    record_progress(ctx, depth, path, state, -1, Nil)
    return true
  }

  // ---- 2. 缓存查找：该 (状态, 剩余集合) 若已证明失败，直接返回 ----
  let key = cache_key(state, remaining)
  match ctx.cache.get(key) {
    Some(_) => {
      ctx.cache_hits = ctx.cache_hits + 1
      // 只缓存"确定失败"，所以命中即失败
      return false
    }
    None => ()
  }

  // ---- 3. 计算候选 ----
  let (min_idx, min_end) = min_end_of(ops, remaining)
  if min_idx < 0 {
    // 防御性分支：depth < total 时必有剩余，正常不会走到
    return false
  }
  let candidates = collect_candidates(ops, remaining, min_end)

  // ---- 4. 按确定顺序逐个尝试 ----
  //
  // 失败分两类，都要进反例证据（L1）：
  //   - `first_value_fail`：模型能执行但返回值与历史不符
  //   - `first_illegal`：模型在此状态下拒绝执行（返回 None）
  //
  // 旧版只记录第一类 —— 对 counter 这类「某些转换物理不可能」的模型，
  // 真正的肇因往往是第二类：历史里 W=3[12,20] 被实时序钉死在 W=5[0,10]
  // 之后，而 counter 拒绝 3 <= 5 的回退。证据里只有合法的 W=5，肇事的
  // W=3 完全不见，`check(violation.ops) == Linearizable` —— 反例链条断了。
  //
  // 两类都记时优先保留更深层的记录；同层里 first_value_fail 的解释信息
  // 更丰富（有期望值可对照），所以 value_fail 优先展示。
  let mut first_value_fail = -1
  let mut first_value_fail_expected = Nil
  let mut first_illegal = -1
  let mut found = false
  let mut i = 0
  while i < candidates.length() && !found {
    let idx = candidates[i]
    let op = ops[idx]
    match model.apply(state, op.kind) {
      Some((next_state, expected)) =>
        if result_matches(
            model,
            state,
            op.kind,
            expected,
            op.result,
            config.allow_unknown_results,
          ) {
          // 这一步合法 → 深入一层
          remaining[idx] = false
          path.push(idx)
          let ok = dfs(
            ctx,
            model,
            ops,
            remaining,
            next_state,
            depth + 1,
            path,
            config,
          )
          ignore(path.pop())
          remaining[idx] = true
          if ctx.timed_out {
            return false
          }
          if ok {
            found = true
          }
          // 状态可执行，但模型期望的返回值与历史不符 → 该候选被剪枝
        } else if first_value_fail < 0 {
          first_value_fail = idx
          first_value_fail_expected = expected
        }
      None =>
        // 模型说此状态下该操作物理不可能 → 剪枝，但要留下证据
        if first_illegal < 0 {
          first_illegal = idx
        }
    }
    i = i + 1
  }

  if found {
    record_progress(ctx, depth, path, state, -1, Nil)
    return true
  }

  // ---- 5. 全部候选失败：记录进度，写入缓存 ----
  // 值不匹配优先（解释更具体）；没有值失败但有模型拒绝时用后者。
  if first_value_fail >= 0 {
    record_progress(
      ctx, depth, path, state, first_value_fail, first_value_fail_expected,
    )
  } else {
    record_progress(ctx, depth, path, state, first_illegal, Nil)
  }
  if !ctx.cache_full {
    if ctx.cache.length() < config.max_states {
      ctx.cache[key] = true
    } else {
      ctx.cache_full = true
    }
  }
  false
}

// ============================================================
// 反例解释文本
// ============================================================

///|
/// 生成人类可读的违规解释。
///
/// 四段结构：
/// 1. 一句话结论（最长一致前缀多长）
/// 2. 已线性化的部分（按线性化顺序，说明这一段为什么能解释得通）
/// 3. 卡住的地方：哪个操作无法解释、模型期望什么、历史记录了什么
/// 4. happens-before 证据：谁在它之前就完成了，因而不可能排在它后面
fn build_explanation(
  ops : Array[Operation],
  depth : Int32,
  prefix : Array[Int32],
  state : State,
  fail_idx : Int32,
  fail_expected : OpResult,
  model_name : String,
  explored : Int32,
) -> String {
  let sb = StringBuilder()
  sb.write_string("非线性一致（模型 ")
  sb.write_string(model_name)
  sb.write_string("）：最多可线性化 ")
  sb.write_string(depth.to_string())
  sb.write_string(" / ")
  sb.write_string(ops.length().to_string())
  sb.write_string(" 个操作，之后无路可走。\n")

  if prefix.length() > 0 {
    sb.write_string(
      "\n最长一致前缀（可以按这个顺序解释）：\n",
    )
    for step, idx in prefix {
      sb.write_string("  ")
      sb.write_string((step + 1).to_string())
      sb.write_string(". ")
      sb.write_string(format_op(ops[idx]))
      sb.write_string("\n")
    }
    sb.write_string("  此后模型状态 = ")
    sb.write_string(state_to_string(state))
    sb.write_string("\n")
  }

  if fail_idx >= 0 {
    let bad = ops[fail_idx]
    sb.write_string("\n无法解释的操作：\n  ")
    sb.write_string(format_op(bad))
    sb.write_string("\n")
    if fail_expected is Nil {
      // fail_expected == Nil：模型在此状态下拒绝执行该操作（返回 None）
      // —— 转换物理不可能，而不是返回值不匹配。
      sb.write_string(
        "  模型在该状态下拒绝执行此操作：该转换在语义上不可能（例如单调计数器的回退、对空队列的出队）。\n",
      )
    } else {
      sb.write_string("  模型在该状态下期望 ")
      sb.write_string(format_op_result(fail_expected))
      sb.write_string("，而历史记录为 ")
      sb.write_string(format_op_result(bad.result))
      sb.write_string("。\n")
    }

    let before : Array[Operation] = []
    for op in ops {
      // 按对象相等排除 bad 自身，而不是按 id：id 只是报告用标签，不保证
      // 唯一（audit_test 已锁定重复 id 合法）。按 id 过滤会把另一个
      // 同 id、但真正 happens-before 的操作从证据里误删。
      if op != bad && happens_before(op, bad) {
        before.push(op)
      }
    }
    if before.length() > 0 {
      sb.write_string(
        "\n被迫先于它完成的操作（end < start，二者不并发）：\n",
      )
      for op in before {
        sb.write_string("  ")
        sb.write_string(format_op(op))
        sb.write_string("\n")
      }
    }
  } else {
    sb.write_string(
      "\n该前缀之后没有任何操作能同时满足候选条件与模型语义。\n",
    )
  }

  sb.write_string("\n搜索节点数：")
  sb.write_string(explored.to_string())
  sb.write_string("\n")
  sb.to_string()
}

// ============================================================
// 内部公共流程
// ============================================================

///|
/// 构造搜索上下文。
fn make_search_state(model_init : State, config : CheckConfig) -> SearchState {
  let no_deadline = config.time_budget_ms <= 0
  let deadline = if no_deadline {
    0UL
  } else {
    @env.now() + config.time_budget_ms.to_uint64()
  }
  {
    cache: Map([]),
    explored: 0,
    cache_hits: 0,
    deadline,
    no_deadline,
    timed_out: false,
    cache_full: false,
    recorded: false,
    best_depth: 0,
    best_prefix: [],
    best_state: model_init,
    best_fail: -1,
    best_fail_expected: Nil,
  }
}

///|
/// 检查区间合法性；非法时返回错误描述。
fn validate_intervals(ops : Array[Operation]) -> String? {
  for op in ops {
    if op.start > op.end {
      return Some(
        "操作 " +
        op.id.to_string() +
        " 的时间区间非法：start=" +
        op.start.to_string() +
        " > end=" +
        op.end.to_string(),
      )
    }
  }
  None
}

///|
/// 从搜索上下文组装 `Violation`。
fn build_violation(
  ctx : SearchState,
  ops : Array[Operation],
  model_name : String,
) -> Violation {
  // 相关操作 = 最长一致前缀 + 卡住的那个。
  //
  // **按 ops 下标收集，不按 id 去重**：项目自身测试（audit_test.mbt）已
  // 锁定「重复 id 合法」，而同一 id 完全可以属于两条不同内容的操作
  // （例如 dup-id 反例里的 `W=2` 与 `R->1` 都是 id=1）。旧的「按 id 去重 +
  // 再按 id 反查挑操作」会让重复 id 只保留首个匹配项，见证里丢掉真正
  // 卡住的那条操作 —— 挑出来的子集线性一致，`shrink` 因此判定
  // 「种子本身不违规」而 abort，minimize 在 CLI 上表现为运行时崩溃。
  let subset : Array[Operation] = []
  for idx in ctx.best_prefix {
    subset.push(ops[idx])
  }
  if ctx.best_fail >= 0 {
    subset.push(ops[ctx.best_fail])
  }

  // 按 **id 升序** 组装（API.md 承诺 witness 按 id 升序）。旧实现按文件
  // 行序遍历 ops，行序被打乱的历史会输出 2,0,1 这样的乱序见证，而
  // minimize 走 sort_ops_by_id 是升序 —— 两条路径输出不一致。
  //
  // MoonBit 的 Array::sort_by 是稳定排序，所以同 id 的条目保持
  // best_prefix 里的原始相对顺序，输出可复现。
  subset.sort_by(fn(a, b) { a.id - b.id })

  // 兜底：连一步都没走通（例如第一个操作就不合法）时报告全部操作，
  // 否则上游拿不到任何证据。
  let final_ops = if subset.length() == 0 { ops.copy() } else { subset }

  Violation::{
    ops: final_ops,
    depth: ctx.best_depth,
    explanation: build_explanation(
      ops,
      ctx.best_depth,
      ctx.best_prefix,
      ctx.best_state,
      ctx.best_fail,
      ctx.best_fail_expected,
      model_name,
      ctx.explored,
    ),
  }
}

// ============================================================
// 对外入口
// ============================================================

///|
/// 检查一段历史是否线性一致（泛型版，编译期单态化）。
///
/// - `Linearizable`：存在合法全序
/// - `Violation(v)`：不存在，`v` 带最长一致前缀与解释
/// - `Unknown(reason)`：时间预算耗尽或输入区间非法
pub fn[M : Model] check_with(
  history : History,
  model : M,
  config : CheckConfig,
) -> CheckOutcome {
  let ops = history.operations

  // 空历史平凡线性一致
  if ops.length() == 0 {
    return Linearizable
  }

  // 区间必须合理（start <= end），否则语义无从谈起
  match validate_intervals(ops) {
    Some(reason) => return Unknown(reason)
    None => ()
  }

  let ctx = make_search_state(model.init(), config)
  let remaining : Array[Bool] = []
  for _ in ops {
    remaining.push(true)
  }
  let path : Array[Int32] = []
  let ok = dfs(ctx, model, ops, remaining, model.init(), 0, path, config)

  if ctx.timed_out {
    return Unknown(
      "超过时间预算 " +
      config.time_budget_ms.to_string() +
      "ms（已探索 " +
      ctx.explored.to_string() +
      " 个搜索节点）",
    )
  }
  if ok {
    return Linearizable
  }
  Violation(build_violation(ctx, ops, model.name()))
}

///|
/// 用 `AnyModel` 做运行期分发的检查入口（CLI 用这个）。
///
/// 内部拆包后走泛型版本，避免为每种模型重写一遍搜索。
pub fn check(
  history : History,
  model : AnyModel,
  config : CheckConfig,
) -> CheckOutcome {
  match model {
    Register(m) => check_with(history, m, config)
    Counter(m) => check_with(history, m, config)
    Set(m) => check_with(history, m, config)
    Queue(m) => check_with(history, m, config)
  }
}

///|
/// `check` 的同义入口（契约里出现过两种命名，都保留）。
pub fn check_any(
  history : History,
  model : AnyModel,
  config : CheckConfig,
) -> CheckOutcome {
  check(history, model, config)
}

///|
/// 用默认配置检查。
pub fn check_default(history : History, model : AnyModel) -> CheckOutcome {
  check(history, model, CheckConfig::default())
}

// ============================================================
// 诊断：搜索统计
// ============================================================

///|
/// 搜索统计，用于回答"访问了多少状态"、验证缓存是否真的省了工作。
pub(all) struct CheckStats {
  /// 访问的搜索节点数
  explored : Int32
  /// 缓存命中次数
  cache_hits : Int32
  /// 缓存最终条目数
  cache_size : Int32
  /// 是否超时
  timed_out : Bool
} derive(Debug)

///|
/// 跑一次检查并同时返回统计信息。
///
/// 判定逻辑与 `check_with` 完全共用同一套 `dfs`，只是多带计数。
pub fn[M : Model] check_with_stats(
  history : History,
  model : M,
  config : CheckConfig,
) -> (CheckOutcome, CheckStats) {
  let ops = history.operations
  let empty_stats = CheckStats::{
    explored: 0,
    cache_hits: 0,
    cache_size: 0,
    timed_out: false,
  }
  if ops.length() == 0 {
    return (Linearizable, empty_stats)
  }
  match validate_intervals(ops) {
    Some(reason) => return (Unknown(reason), empty_stats)
    None => ()
  }

  let ctx = make_search_state(model.init(), config)
  let remaining : Array[Bool] = []
  for _ in ops {
    remaining.push(true)
  }
  let path : Array[Int32] = []
  let ok = dfs(ctx, model, ops, remaining, model.init(), 0, path, config)

  let stats = CheckStats::{
    explored: ctx.explored,
    cache_hits: ctx.cache_hits,
    cache_size: ctx.cache.length(),
    timed_out: ctx.timed_out,
  }

  if ctx.timed_out {
    return (
      Unknown("超过时间预算 " + config.time_budget_ms.to_string() + "ms"),
      stats,
    )
  }
  if ok {
    return (Linearizable, stats)
  }
  (Violation(build_violation(ctx, ops, model.name())), stats)
}
