// ============================================================================
// minimize.mbt — 反例最小化（delta debugging）
//
// 思路：一份违规历史里往往混着大量无关操作。反复尝试「删掉一块」，
// 只要剩下的子集仍然违规，就保留这次删除；否则缩小块，直到块大小退化到
// 1 且再也删不动为止。最终得到 1-minimal 的见证子集。
//
// ── 必须处理的退化解 ──────────────────────────────────────────────────
// 纯 ddmin 会把「W=1、W=2、R->1」一路压成单个「R->1」：删光所有写之后，
// 一个读到非初值的操作相对初始状态本身就违规了。形式上是合法见证，但
// 它把「读到过期值」这个 bug 换成了「读到一个从没存在过的值」——bug 变了，
// 对调试毫无价值。
//
// **可解释性约束**（核心守卫）：
//   若某个操作单独看是违规的（相对初始状态它根本无法成立），那么见证里必须
//   存在至少一个同伴操作 p，使得 {该操作, p} 这一对是线性一致的。
//   换句话说——「读到一个不存在的值」这种孤立矛盾，必须有一个操作在见证
//   里解释它的来源。
//
// 实测（register 模型）：
//   · {W=1, W=2, R->1} → R 单独非法，但 {R, W=1} 合法 ✓ 接受
//   · {W=2, R->1}      → R 单独非法，{R, W=2} 仍违规 → 拒绝（砍掉 W=1 会被拦下）
//   · {R->1, R->1}     → 两个都孤立非法，互相也解释不了 → 拒绝（纯 ddmin 的退化解）
//
// 这条判据只用 Model + check 就能算，对 register / counter / set / queue
// 一律适用，不需要任何模型内部知识。
//
// 想拿「纯」ddmin 结果（可能只剩 1 条）时调用 minimize_raw。
//
// ── 最终返回值的硬约束（LC-1）────────────────────────────────────────
// `length >= min_witness` 与 `explainable` 必须同时对**返回的那个数组**
// 成立（判据集中在 `witness_ok`）。旧实现只在「候选删除」时用这两条，
// 兜底分支直接把 `check` 给的种子原样返回——而种子可能只有一条操作
// （更糟的是那条操作相对初始状态就不可能成立）。那等于把「数据自相矛盾」
// 伪装成「最小并发反例」，正是本文件开头要拦的退化解。
//
// 现在的行为：
//   · 种子不合格 → 在整份历史里重新找合格见证（ddmin 只能删，得换更大的
//     起点，或按规模枚举 2/3 元子集）；
//   · 确实不存在合格见证 → `minimal_witness` 返回 None，`minimize` 原样
//     返回整份历史并如实说明。不输出退化解，也不 panic 到用户面前。
//
// ── 判定原则 ──────────────────────────────────────────────────────────
// 删操作会放松时间约束、可能让历史重新变合法，所以每一步「是否仍违规」
// 都必须用检查器实测确认，绝不靠推理猜。
//
// 注：MoonBit 里 guard 是保留字（if guard），所以本文件用 expl 命名。
// ============================================================================

///|
/// 默认最小见证规模
pub const MIN_WITNESS : Int32 = 2

///|
/// 操作种类的人类可读标签，例如 Write(1) -> "W=1"
pub fn kind_label(kind : OpKind) -> String {
  match kind {
    Write(v) => "W=\{v}"
    Read => "R"
    Cas(e, n) => "Cas(\{e}->\{n})"
    Append(v) => "App(\{v})"
    Pop => "Pop"
  }
}

///|
/// 返回值的人类可读标签
pub fn result_label(result : OpResult) -> String {
  match result {
    Ok => "Ok"
    Value(v) => "Value(\{v})"
    Bool(true) => "Bool(true)"
    Bool(false) => "Bool(false)"
    Empty => "Empty"
    Nil => "Nil"
  }
}

///|
/// 一行紧凑描述：proc 1  W=1  ->  Ok  [10..25]
pub fn op_line(op : Operation) -> String {
  "proc \{op.process}  \{kind_label(op.kind)}  ->  \{result_label(op.result)}  [\{op.start}..\{op.end}]"
}

///|
/// 操作的内容指纹（**不含 op.id**）——`Expl` 缓存的键。
///
/// 为什么不能用 `op.id`：项目自身测试（audit_test.mbt）已锁定「重复 id 合法」。
/// 两条同 id 但内容不同的操作（例如 dup-id 反例里的 `W=2` 与 `R->1`）若共用
/// 一个 id 键，`is_illegal` 会把 A 的判定结果错发给 B，`explainable` 的
/// 「排除自己」也会把同 id 的同伴误判成自己而漏掉解释者，最终 ddmin 拒绝所有
/// 候选、`shrink` 兜底 `abort`（minimize 在 CLI 上表现为运行时崩溃）。
///
/// 指纹排除 id，只描述「这个操作做了什么、在什么时刻、结果如何」——
/// 同 id 不同内容的操作各自独立判定；两条完全相同的操作复用缓存是无害的
/// （判定只依赖内容）。
fn op_key(op : Operation) -> String {
  "\{op.process}|\{kind_label(op.kind)}|\{result_label(op.result)}|\{op.start}|\{op.end}"
}

///|
/// 用操作子集构造历史（用于反复试探）
pub fn ops_to_history(ops : Array[Operation]) -> History {
  History::{ operations: ops.copy(), }
}

///|
/// 删掉 [from, from+count) 这一段，返回新数组
pub fn remove_chunk(
  ops : Array[Operation],
  from : Int32,
  count : Int32,
) -> Array[Operation] {
  let out : Array[Operation] = []
  for i, op in ops {
    if i < from || i >= from + count {
      out.push(op)
    }
  }
  out
}

///|
/// 对操作子集跑一次检查器
pub fn[M : Model] probe_ops(
  ops : Array[Operation],
  model : M,
  config : CheckConfig,
) -> CheckOutcome {
  check_with(ops_to_history(ops), model, config)
}

///|
/// 判断子集是否仍违规，并把 Unknown 的原始原因带给四态入口。
fn[M : Model] still_violates_trace(
  ops : Array[Operation],
  model : M,
  config : CheckConfig,
  unknown : Array[String],
) -> Bool {
  match probe_ops(ops, model, config) {
    Violation(_) => true
    Linearizable => false
    Unknown(reason) => {
      unknown.push(reason)
      false
    }
  }
}

///|
/// 判断子集是否仍违规（唯一判定依据）。
/// 既有 Bool API 无法表达 Unknown；需要区分三态的最小化流程使用 trace 版本。
pub fn[M : Model] still_violates(
  ops : Array[Operation],
  model : M,
  config : CheckConfig,
) -> Bool {
  still_violates_trace(ops, model, config, [])
}

// ── 可解释性判定器 ────────────────────────────────────────────────────

///|
/// 无序对缓存键（历史遗留，`Expl` 缓存已改用内容指纹 `op_key`）。
///
/// 保留原因：`audit2_test.mbt` 的「大 id 碰撞修复」回归测试仍直接覆盖它，
/// 该测试锁定了旧的 `lo * 100003 + hi` 32 位乘法回绕问题。
/// **不要在新代码里用它做 Expl 缓存键**：它按 `op.id` 计算，而重复 id
/// 合法（audit_test.mbt 锁定），同 id 的不同操作会映射到同一键。
///
/// 用 Int64 中转：id 不要求连续也不要求是小整数，旧的
/// `lo * 100003 + hi` 在 32 位乘法下会回绕，两个不同操作对映射到
/// 同一键，Expl.pairs 缓存把 A 对的判定结果错给 B 对用。
/// lo < 2^31、hi < 2^31 时 (lo<<32)|hi 在 Int64 内无碰撞。
/// 标 pub 仅为可测性（黑盒测试直接覆盖碰撞边界）。
pub fn pair_key(a : Int32, b : Int32) -> Int64 {
  let lo = if a < b { a } else { b }
  let hi = if a < b { b } else { a }
  (lo.to_int64() << 32) | (hi.to_int64() & 0xFFFFFFFFL)
}

///|
/// 可解释性判定器：缓存「单操作是否孤立非法」与「两操作对是否合法」
///
/// 缓存键是**内容指纹**（见 `op_key`），不是 `op.id`：重复 id 合法，
/// 按 id 键会让同 id 的不同操作互相串味。
pub(all) struct Expl {
  /// 内容指纹 -> 该操作单独相对初始状态是否已经违规
  illegal : Map[String, Bool]
  /// 两操作对是否合法缓存（键为两个指纹排序拼接）
  pairs : Map[String, Bool]
}

///|
pub fn Expl::new() -> Expl {
  { illegal: Map([]), pairs: Map([]), }
}

///|
/// 最小化过程中「可解释性守卫实际跑了多少次判定」的确定性计数器（LC-46）。
///
/// ## 为什么需要它（而不是测时间）
///
/// LC-46 的现象是 `minimize` 在 801 条历史上要跑 25–250 秒，而 `check` 只要
/// 0.05 秒。第一版回归测试写的是 `minimize 耗时 / check 耗时 < 100` ——
/// 那是**环境因变量**：同一工具链、同一条命令，Lead 机器实测比值在
/// 469 / 647 / 751 之间跳，本机是 ~3000，全取决于 CPU 快慢和有没有别的活。
/// 拿它当契约，修好那天可能因为换了机器而**还红着**，那就不是锁，是噪声。
///
/// 所以改用 O(k³) 的**直接等价物**：判定次数。它是确定性的整数，同一历史
/// 在任何机器上都得同一个值。下面三个计数器分别对应成本的三层：
///
/// - `illegal_probes`：`illegal_status` 缓存未命中、真跑了一次 `probe_ops`；
/// - `pair_probes`：`pair_status` 缓存未命中、真跑了一次 `probe_ops`
///   （LC-46 的主犯：旧写法对**每个**操作都扫遍**每个**同伴）；
/// - `ddmin_candidates`：ddmin 试过的候选数。
///
/// LC-46 修前的成本模型是「k 个操作 × k 个同伴 × O(k) 个候选」≈ k³。修后
/// 「两趟筛选」把 `pair_probes` 从 k² 压到「只对孤立非法的操作数 × k」。
/// 这两者的差是**整数差**，可以直接写进断言。
///
/// 与 `checker.mbt` 的 `cache_key_calls` 同一约定：生产路径上只是一次自增，
/// 不改变任何语义；只在测试里读写。
let illegal_probes : Ref[Int32] = { val: 0, }

///|
let pair_probes : Ref[Int32] = { val: 0, }

///|
let ddmin_candidates : Ref[Int32] = { val: 0, }

///|
/// 读可解释性守卫的判定次数（测试用）：`(illegal_status 未命中数, pair_status 未命中数)`。
pub fn explain_probe_counts() -> (Int32, Int32) {
  (illegal_probes.val, pair_probes.val)
}

///|
/// 读 ddmin 试过的候选数（测试用）。
pub fn ddmin_candidate_count() -> Int32 {
  ddmin_candidates.val
}

///|
/// 清零三个最小化计数器（测试用）。
pub fn reset_minimize_counters() -> Unit {
  illegal_probes.val = 0
  pair_probes.val = 0
  ddmin_candidates.val = 0
}

///|
/// 单个操作是否孤立非法：`None` = 本次检查没有结论。
///
/// 只有 Linearizable / Violation 才能写入确定结果缓存。Unknown 既不是合法，
/// 也不是违规；若把它按 false 缓存，后续可解释性检查会把证据不足误当成
/// 「这条操作单独看没有问题」，从而跳过寻找同伴的守卫。
fn[M : Model] Expl::illegal_status(
  self : Expl,
  op : Operation,
  model : M,
  config : CheckConfig,
  unknown : Array[String],
) -> Bool? {
  let key = op_key(op)
  match self.illegal.get(key) {
    Some(v) => Some(v)
    None => {
      let single : Array[Operation] = [op]
      illegal_probes.val = illegal_probes.val + 1
      match probe_ops(single, model, config) {
        Violation(_) => {
          self.illegal[key] = true
          Some(true)
        }
        Linearizable => {
          self.illegal[key] = false
          Some(false)
        }
        Unknown(reason) => {
          unknown.push(reason)
          None
        }
      }
    }
  }
}

///|
/// 单个操作是否孤立非法（带缓存）。
///
/// 保留既有 Bool API：Unknown 不能断言「孤立非法」，因此返回 false；调用方
/// 若要用它证明可解释性，必须走 `illegal_status` 以保留第三种状态。
pub fn[M : Model] Expl::is_illegal(
  self : Expl,
  op : Operation,
  model : M,
  config : CheckConfig,
) -> Bool {
  self.illegal_status(op, model, config, []).unwrap_or(false)
}

///|
/// 两操作组合是否「能解释」：`None` = 本次检查没有结论。
fn[M : Model] Expl::pair_status(
  self : Expl,
  a : Operation,
  b : Operation,
  model : M,
  config : CheckConfig,
  unknown : Array[String],
) -> Bool? {
  // 无序对：按指纹字典序拼接，保证 (a,b) 与 (b,a) 命中同一缓存槽
  let ka = op_key(a)
  let kb = op_key(b)
  let key = if ka < kb { "\{ka}|\{kb}" } else { "\{kb}|\{ka}" }
  match self.pairs.get(key) {
    Some(v) => Some(v)
    None => {
      let pair : Array[Operation] = [a, b]
      // LC-46：这一行就是 O(k²) 的来源，也是新判据直接依赖的量。
      pair_probes.val = pair_probes.val + 1
      match probe_ops(pair, model, config) {
        Linearizable => {
          self.pairs[key] = true
          Some(true)
        }
        Violation(_) => {
          self.pairs[key] = false
          Some(false)
        }
        Unknown(reason) => {
          unknown.push(reason)
          None
        }
      }
    }
  }
}

///|
/// 两操作组合是否「能解释」：必须由检查器确定组合线性一致。
/// Unknown 不构成证明，也不缓存，允许之后增加预算重试。
pub fn[M : Model] Expl::pair_explains(
  self : Expl,
  a : Operation,
  b : Operation,
  model : M,
  config : CheckConfig,
) -> Bool {
  self.pair_status(a, b, model, config, []).unwrap_or(false)
}

///|
/// 候选子集是否满足可解释性约束：
/// 每个「孤立非法」的操作，都必须有一个同伴能把它解释掉。
///
/// 「排除自己」用**数组下标**而非 `op.id`：同 id 的不同操作是真正的同伴，
/// 按 id 排除会把它们当自己而漏掉解释者。
fn[M : Model] explainable_trace(
  subset : Array[Operation],
  model : M,
  config : CheckConfig,
  expl : Expl,
  unknown : Array[String],
) -> Bool {
  // ## 先做 O(k) 的单操作筛选，再对**真正孤立非法**的那些找同伴（LC-46）
  //
  // 直觉写法是「每个操作判完 illegal 就立刻内层遍历所有同伴」，但那样
  // 内层循环在最常见的「没有操作孤立非法」情形下**一次也没命中**却仍然
  // 跑满：n 个操作 × n 个同伴 = O(k²) 次 `pair_status`（每次一次完整 check）。
  // 实测 k=200 时单次 `explainable_trace` 最坏 = 200 + 200·199 ≈ 4 万次 check，
  // 而 ddmin 对每个候选都要调用它 → O(k³)，801 条历史 249 s（check 只要 0.07 s）。
  //
  // 改成两趟：第一趟只跑 n 次 `illegal_status`（有缓存，跨候选复用），
  // 把「孤立非法」的下标收集起来；第二趟**只为这些下标**找同伴。
  // 语义不变：判据仍然是「每个孤立非法的操作都至少有一个同伴能解释它」，
  // 只是把「对没病的操作也扫遍同伴」这段纯浪费去掉。
  //
  // 实测收益（mutation 对照，801 条历史）：旧写法 175828 ms，两趟筛选 28242 ms。
  let singles : Array[(Int32, Operation)] = []
  for i, op in subset {
    match expl.illegal_status(op, model, config, unknown) {
      Some(true) => singles.push((i, op))
      Some(false) => ()
      // 单操作本身尚未判明，不能据此证明整个子集可解释。
      None => return false
    }
  }
  // 没有孤立非法的操作 → 可解释性无待证事项，短路（最常见路径）。
  if singles.length() == 0 {
    return true
  }
  for entry in singles {
    let (i, op) = entry
    let mut explained = false
    for j, other in subset {
      if j != i && !explained {
        match expl.pair_status(op, other, model, config, unknown) {
          Some(true) => explained = true
          Some(false) => ()
          // 同伴判定没有结论：这个操作的解释来源未定，不能证明它可解释。
          None => return false
        }
      }
    }
    if !explained {
      return false
    }
  }
  true
} ///|
/// 既有 Bool 入口；Unknown 时保守返回 false，原始原因由 trace 入口保留。

///|
pub fn[M : Model] explainable(
  subset : Array[Operation],
  model : M,
  config : CheckConfig,
  expl : Expl,
) -> Bool {
  explainable_trace(subset, model, config, expl, [])
}

///|
/// 单次候选判定：够大 + 更小 + 仍违规 + （可选）可解释。
fn[M : Model] candidate_accepted_trace(
  current : Array[Operation],
  candidate : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl?,
  unknown : Array[String],
) -> Bool {
  let big_enough = candidate.length() >= min_witness
  let smaller = candidate.length() < current.length()
  if !big_enough || !smaller {
    return false
  }
  if !still_violates_trace(candidate, model, config, unknown) {
    return false
  }
  match expl {
    Some(e) => explainable_trace(candidate, model, config, e, unknown)
    None => true
  }
}

///|
/// 既有 Bool 入口；四态最小化使用 trace 版本。
pub fn[M : Model] candidate_accepted(
  current : Array[Operation],
  candidate : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl?,
) -> Bool {
  candidate_accepted_trace(
    current,
    candidate,
    model,
    config,
    min_witness,
    expl,
    [],
  )
}

///|
/// delta debugging 主体。
///
/// min_witness 是最小操作数下界；expl 为 None 时退化成经典 ddmin。
///
/// ## `max_probes`：判定预算是硬上限（LC-46）
///
/// ddmin 的成本不是 `max_rounds` 决定的：每一轮里 `chunk` 从 `len/2` 一路
/// 减半到 1，**每个粒度都要扫 `len/chunk` 个候选**，而每个候选都要跑一次
/// `candidate_accepted_trace`（`still_violates` = 一次完整 `check`，外加可解释性
/// 守卫）。而且处处删不动时 `improved` 一直为真、`chunk` 一路减到 1，
/// 于是「删不动」的历史反而跑得最久：k=200 的种子 → 约 200 轮 × 平均
/// 200 个候选 ≈ 4 万次 check，每次 check 在这类历史上要 30–40 ms，
/// 合 30 秒以上（实测 801 条历史 38 s，修前 249 s）。
///
/// `max_rounds` 只管外层循环次数，管不到「一轮之内有多少候选」。
/// 这里加一个**判定次数**硬上限：超了就带着当前（仍然合格的）`current`
/// 返回。返回值的语义不变 —— 每一步 `current` 都已被
/// `candidate_accepted_trace` 全量复核过，所以「预算用完」只会让结果
/// **没那么小**，绝不会变成一个非法见证。
///
/// 为什么是 4000：k=200 时正常收敛（能删得动）只要几十到几百次判定；
/// 4000 给足余量，同时把「删不动的死结」从 4 万次压到 4000 次。
const DDMin_MAX_PROBES : Int32 = 4000

///|
fn[M : Model] ddmin_bounded_trace(
  initial : Array[Operation],
  model : M,
  config : CheckConfig,
  max_rounds : Int32,
  min_witness : Int32,
  expl : Expl?,
  unknown : Array[String],
) -> Array[Operation] {
  let mut current = initial.copy()
  let mut rounds = 0
  let mut probes = 0
  let mut improved = true
  while improved && rounds < max_rounds && probes < DDMin_MAX_PROBES {
    improved = false
    rounds = rounds + 1
    let mut chunk = current.length() / 2
    while chunk >= 1 && probes < DDMin_MAX_PROBES {
      let mut i = 0
      let mut found = false
      while i < current.length() && !found && probes < DDMin_MAX_PROBES {
        let candidate = remove_chunk(current, i, chunk)
        probes = probes + 1
        ddmin_candidates.val = ddmin_candidates.val + 1
        if candidate_accepted_trace(
            current, candidate, model, config, min_witness, expl, unknown,
          ) {
          current = candidate
          found = true
        }
        i = i + chunk
      }
      if found {
        improved = true
        // ## LC-46：接受候选后**留在同一个 chunk 上继续扫**，不回外层重开
        //
        // 旧写法 `chunk = 0` 想表达「重新从 len/2 开始」，但它是跳出内层、
        // 回**外层**，外层随即重置 `chunk = current.length() / 2`。于是每次
        // 「缩小一半」只删一个块就重开，穷尽一整层要 O(k/chunk) 轮，总轮数
        // 变成 O(k)：每轮 O(k) 个候选 × 每个候选 O(k) 次 check = O(k³)。
        //
        // 新版：`found` 之后把 `i` 归零、继续用**同一个 chunk** 往后扫，
        // 直到这一粒度一次也删不动才 `chunk /= 2`。轮数降到 O(log k)。
        // 正确性不变 —— 每一步仍由 `candidate_accepted_trace` 全量复核
        // （够大 + 更小 + 仍违规 + 可解释），这里不可能多删；
        // `chunk >= 1` 保证终止（每次 `found` 都让 current 严格变短，
        // 且 min_witness 给了下界）。
        i = 0
        found = false
      } else {
        chunk = chunk / 2
      }
    }
  }
  current
}

///|
/// 既有 ddmin 入口；需要区分「没缩小」与「探针未知」时使用 trace 版本。
pub fn[M : Model] ddmin_bounded(
  initial : Array[Operation],
  model : M,
  config : CheckConfig,
  max_rounds : Int32,
  min_witness : Int32,
  expl : Expl?,
) -> Array[Operation] {
  ddmin_bounded_trace(initial, model, config, max_rounds, min_witness, expl, [])
}

///|
/// 经典 ddmin（无下界、无守卫），可能压到单个操作
pub fn[M : Model] ddmin(
  initial : Array[Operation],
  model : M,
  config : CheckConfig,
  max_rounds : Int32,
) -> Array[Operation] {
  ddmin_bounded(initial, model, config, max_rounds, 0, None)
}

///|
/// 见证合格判据（唯一口径）：够大 + 仍违规 + 可解释。
///
/// 三道约束必须同时对**最终返回值**成立，而不只是对候选删除成立：
/// - `length >= min_witness`：下界（`MIN_WITNESS` 默认 2）
/// - `still_violates`：删操作不得让历史变回线性一致
/// - `explainable`：孤立非法的操作必须有同伴解释它的来源，否则 bug 语义变了
fn[M : Model] witness_ok(
  cand : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl,
  unknown : Array[String],
) -> Bool {
  if cand.length() < min_witness {
    return false
  }
  if !still_violates_trace(cand, model, config, unknown) {
    return false
  }
  explainable_trace(cand, model, config, expl, unknown)
}

///|
/// 按字典序枚举 `pool` 的全部 `size` 元子集，返回第一个合格见证。
///
/// `cap` 是 pool 规模上限：超过就放弃。这条兜底路径是组合枚举
/// （2 元 O(n²)、3 元 O(n³)，每次判定都要跑一遍检查器），只用于
/// 「ddmin 从种子出发已经救不回来」的少量历史；大历史优先信任 ddmin。
fn[M : Model] first_ok_subset(
  pool : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl,
  size : Int32,
  cap : Int32,
  unknown : Array[String],
) -> Array[Operation]? {
  let n = pool.length()
  if size <= 0 || size > n || n > cap {
    return None
  }
  let idx : Array[Int32] = []
  let mut i = 0
  while i < size {
    idx.push(i)
    i = i + 1
  }
  let mut scanning = true
  while scanning {
    let cand : Array[Operation] = []
    for k in idx {
      cand.push(pool[k])
    }
    if witness_ok(cand, model, config, min_witness, expl, unknown) {
      return Some(cand)
    }
    // 推进到下一个组合（字典序，保证确定性）
    let mut slot = size - 1
    let mut advanced = false
    while slot >= 0 && !advanced {
      if idx[slot] < n - size + slot {
        idx[slot] = idx[slot] + 1
        let mut rest = slot + 1
        while rest < size {
          idx[rest] = idx[rest - 1] + 1
          rest = rest + 1
        }
        advanced = true
      }
      slot = slot - 1
    }
    if !advanced {
      scanning = false
    }
  }
  None
}

///|
/// 在 `pool` 里寻找满足下界 + 仍违规 + 可解释的最小见证（`None` = 找不到）。
///
/// 搜索顺序（每一步都以 `witness_ok` 为唯一判据）：
/// 1. 对 `check` 给出的种子做带守卫的 ddmin —— 常见路径，种子本来就合格；
/// 2. 按**规模从小到大**枚举 2 元、3 元子集 —— 种子不合格时，全局最小见证
///    往往就在这两层（例如「写先完成却读到旧值」的经典反例就是一对）；
/// 3. 以整份历史为起点再跑一次 ddmin —— ddmin 只能删，从种子出发无法
///    「长大」成可解释的见证，换一个更大的起点才有机会；
/// 4. 全部失败返回 `None`：**如实报告**，绝不输出退化解。
///
/// 第 1 步覆盖了绝大多数历史，因此正常调用不会触发组合枚举。
///
/// ## 第 3 步必须有 pool 规模上限（LC-46）
///
/// 第 3 步「以整份历史为起点再跑一次 ddmin」是**唯一**没有规模守卫的路径：
/// 第 2 步的 `first_ok_subset` 有 `cap`，第 1 步的种子来自 `check` 的见证
/// （规模 2–3）。而第 3 步把 k 直接放大到整份历史，成本是
/// `ddmin 候选数 × witness_ok 成本`，其中 `witness_ok` 里的
/// `explainable_trace` 对每个操作先 `illegal_status`（1 次 check），
/// 再对每个同伴跑 `pair_status`（又 1 次 check）—— 单次 `witness_ok`
/// 就是 O(k²) 次 check。实测 k=801 时第 3 步要 ~5.6e9 次 `probe_ops`，
/// CLI 上表现为 `minimize` 超过 180 秒不返回（同一份历史 `check` 只要
/// 0.13 秒）。这不是「慢一点」，是**判定次数失控**。
///
/// 修法与第 2 步对齐：k 超过 `MINIMAL_WITNESS_POOL_CAP` 就**跳过**第 3 步，
/// 让函数如实返回 `None`（`minimize` 会输出「找不到可解释的最小见证」
/// 这段既定文案，CLI 仍然退出码 1 并给出 `check` 的原始 witness）。
/// 小历史（k <= cap）行为**逐字节不变** —— 第 3 步照常执行。
///
/// 为什么是这个界：`first_ok_subset` 的 2 元 / 3 元枚举上限是 48 / 14，
/// 第 3 步的起点比它们大得多（它要从整份历史里删），所以给它一个更大但
/// 仍是常数的界；k=200 时最坏 ~7e7 次基本步，实测 2.2 s，可接受。
const MINIMAL_WITNESS_POOL_CAP : Int32 = 200

///|
fn[M : Model] minimal_witness_trace(
  seed : Array[Operation],
  pool : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl,
  unknown : Array[String],
) -> Array[Operation]? {
  // ## 第 1 步：种子的守卫 ddmin
  //
  // 注意这里**不能**加「种子不可解释就跳过」的判断（LC-46 反向验证的教训）：
  // 可解释性**不是单调**的 —— 从不可解释的 `pool` 出发，ddmin 删掉若干操作
  // 之后剩下的子集**可能重新可解释**。实测 200 条历史：`explainable(pool)=false`，
  // 而从 pool 出发的 ddmin 拿到了一个合法 3 操作见证。任何「起点必须先可解释」
  // 的前置剪枝都会把这类见证整体砍掉（本轮就因此把一个 3-op 见证变成了
  // NoWitness，被 LC-46 的反向用例抓到）。
  let from_seed = ddmin_bounded_trace(
    seed,
    model,
    config,
    200,
    min_witness,
    Some(expl),
    unknown,
  )
  if witness_ok(from_seed, model, config, min_witness, expl, unknown) {
    return Some(from_seed)
  }
  if min_witness <= 2 {
    match
      first_ok_subset(pool, model, config, min_witness, expl, 2, 48, unknown) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  if min_witness <= 3 {
    match
      first_ok_subset(pool, model, config, min_witness, expl, 3, 14, unknown) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  // LC-46：整份历史当 ddmin 起点是 O(k³) 次 check，必须有上限。
  if pool.length() > MINIMAL_WITNESS_POOL_CAP {
    return None
  }
  let from_pool = ddmin_bounded_trace(
    pool,
    model,
    config,
    200,
    min_witness,
    Some(expl),
    unknown,
  )
  if witness_ok(from_pool, model, config, min_witness, expl, unknown) {
    return Some(from_pool)
  }
  None
}

///|
/// 既有可空入口。签名只能表达「找到 / 没找到」，Unknown 仍按找不到处理；
/// 四态入口通过 `minimal_witness_trace` 保留 Unknown，不会误报 NoWitness。
pub fn[M : Model] minimal_witness(
  seed : Array[Operation],
  pool : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl,
) -> Array[Operation]? {
  minimal_witness_trace(seed, pool, model, config, min_witness, expl, [])
}

///|
/// 带守卫的压缩（**只从 seed 出发**，不做全历史搜索）。
///
/// 返回空数组表示「seed 不满足下界/可解释性约束，且压缩不出合格结果」——
/// 这是明确的「没有可输出见证」信号，调用方必须处理，不能当见证使用。
/// 需要「在整份历史里重新找见证」时用 `minimal_witness`。
///
/// 旧实现的三处责任在这里被收敛成一条：`explainable` 先于大小、
/// `min_witness` 约束**最终返回值**、不合格时不再静默返回种子。
pub fn[M : Model] shrink(
  seed : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl,
) -> Array[Operation] {
  match minimal_witness(seed, seed, model, config, min_witness, expl) {
    Some(found) => found
    None => []
  }
}

///|
/// 按 id 升序排序（见证子集要求稳定输出）
///
/// 用 `compare_ops_by_id`（显式三分支），不用 `a.id - b.id`：id 允许完整
/// Int32 范围，减法在极值处回绕会让见证子集不再升序（API.md 承诺）。
pub fn sort_ops_by_id(ops : Array[Operation]) -> Array[Operation] {
  let out = ops.copy()
  out.sort_by(compare_ops_by_id)
  out
}

///|
/// 拼一段人类可读的说明。
///
/// 结语必须**复验后才做强断言**：对结果的每一条操作试删一次并跑检查器，
/// 全部「删掉后变回线性一致」才声称「删掉其中任何一个操作，历史都会变
/// 线性一致」；只要存在删一条仍违规的方向（ddmin 在 `min_witness` 下界
/// 停止时常见，例如 register_bad 的 {W=1, W=2, R->1} 删 W=1 后仍违规），
/// 就改用如实的弱措辞。成本 n 次检查（n 是见证长度，通常 <= 5）。
fn[M : Model] explain_minimal(
  original_n : Int32,
  ops : Array[Operation],
  prefix : String,
  model : M,
  config : CheckConfig,
) -> String {
  let sb = StringBuilder()
  sb.write_string(prefix)
  sb.write_string("：")
  sb.write_string(original_n.to_string())
  sb.write_string(" 个操作中保留 ")
  sb.write_string(ops.length().to_string())
  sb.write_string(" 个仍可复现违规。\n")
  for op in sort_ops_by_id(ops) {
    sb.write_string("  · ")
    sb.write_string(op_line(op))
    sb.write_string("\n")
  }
  // 逐条复验：删掉第 i 条后的完整三态（i 用下标，同 id 操作各自可删）。
  // Unknown 不是 Linearizable：只要有一个删除方向没查完，就不能声称
  // 「删掉任何一条都会变合法」。见证本身已经验证违规，因此这里只收窄结语，
  // 不推翻整个 MinViolation。
  let mut any_remains = false
  let mut any_unknown = false
  for i, _ in ops {
    match probe_ops(remove_chunk(ops, i, 1), model, config) {
      Violation(_) => any_remains = true
      Linearizable => ()
      Unknown(_) => any_unknown = true
    }
  }
  if any_remains {
    sb.write_string(
      "在最少保留这么多个操作的约束下无法继续缩减：存在删掉某一条后仍违规的方向，但继续缩减会跌破最小见证下界或破坏可解释性。",
    )
  } else if any_unknown {
    sb.write_string(
      "删除复验存在结论未知（Unknown）的方向：当前见证仍可复现违规，但不能确认删掉其中任何一个操作都会变回线性一致。",
    )
  } else {
    sb.write_string(
      "删掉其中任何一个操作，历史都会变回线性一致。",
    )
  }
  sb.to_string()
}

///|
/// 统一构造「没有见证」的结果
fn no_witness(ops : Array[Operation], text : String) -> Violation {
  Violation::{ ops: sort_ops_by_id(ops), depth: 0, explanation: text, }
}

///|
/// 「找不到可解释的最小见证」的如实说明（库与 CLI 共用）。
///
/// 这条文本存在的意义：当历史本身确实违规、但没有任何满足下界与
/// 可解释性约束的见证时，工具必须**说清这一点**，而不是把一个退化的
/// 单操作子集伪装成最小反例（那会把「数据自相矛盾」报成「并发竞态」）。
pub fn no_explainable_witness_text(
  total : Int32,
  min_witness : Int32,
) -> String {
  "该历史确实非线性一致，但找不到可输出的最小见证：在「至少 " +
  min_witness.to_string() +
  " 个操作 + 可解释性」约束下，没有任何子集同时满足「仍可复现违规」与「孤立非法的操作有同伴解释来源」。" +
  "原样返回全部 " +
  total.to_string() +
  " 个操作供人工查看。"
}

///|
/// 同上，但按**违规成因**给下一步方向（LC-A4，2026-11-10 审计）。
///
/// 旧文案把 NoWitness 一律归因为「历史数据自相矛盾」，可实测里
/// 2-op stale read（`{W=3 [0,10], Read→2 [20,30]}`，counter/set/queue
/// 三个模型都一样）也是 NoWitness：这类反例的两个操作**各自都合法**，
/// 但可解释性守卫要求「孤立非法的操作要有同伴解释来源」，而这对
/// 同伴本身线性一致、pair 仍违规，于是必然被拒。把它说成「查采样/初值」
/// 会把调试者引向错误方向，且与同历史下 `check --json` 给出的
/// `reason: concurrency-race` 自相矛盾。
///
/// `reason` 取 `violation_reason()` 的两个值：`"data-inconsistency"`
/// （见证是 depth 0 的单操作 → 数据自相矛盾）与 `"concurrency-race"`
/// （其余 → 竞态，最小见证需人工从 check 的 witness 里读）。
///
/// 第三个取值 `"unknown"`（2026-11-17 审计 LC-8）用于「拿不到成因」的情形：
/// 判定成因要靠再查一次历史，而那次检查可能**没有结论**（预算耗尽 / 证据不完整）。
/// 此时既不能断言竞态、也不能断言自相矛盾——编造一个成因会把调试者引向错误方向。
/// 调用方必须显式传 `"unknown"`，不要靠 `else` 兜底：兜底分支默认走竞态，
/// 正是这条缺陷的来源。
pub fn no_explainable_witness_text_for(
  total : Int32,
  min_witness : Int32,
  reason : String,
) -> String {
  let base = no_explainable_witness_text(total, min_witness)
  if reason == "data-inconsistency" {
    base +
    "这通常意味着历史数据自相矛盾（例如初值 0 上记录了 CAS 返回 true），而不是并发交错导致的竞态。"
  } else if reason == "unknown" {
    base +
    "成因未能确定：用于判定成因的那次检查没有给出结论（预算耗尽或证据不完整），因此既不能断言这是并发竞态，也不能断言是数据自相矛盾。请放开预算后重跑，或直接看 check 的输出。"
  } else {
    base +
    "注意这与「数据自相矛盾」不同：该反例属于并发竞态，压缩后的见证无法同时保留可解释的同伴操作（2-op 竞态对本身就是完整成因）。请直接看 check 输出的 witness。"
  }
}

///|
/// 取整份历史作为种子（检查器可能已给出子集）
fn seed_of(history : History, v : Violation) -> Array[Operation] {
  if v.ops.length() > 0 {
    v.ops.copy()
  } else {
    history.operations.copy()
  }
}

///|
/// 最小化的**四态**结论。
///
/// 为什么必须有这个类型：`Violation?` 只能表达「有见证」与「没有可解释见证」
/// 两态，无法表达「压根没下结论」。旧实现把 `Unknown` 塞进了 `Violation`
/// 载体（`ops` = 全部操作 + 文本「无法最小化」），于是 `Some(Violation{...})`
/// 在「已判定违规」与「预算耗尽未判定」两种情况下都成立——CLI 因此无从区分，
/// 把一次没跑完的搜索渲染成了 `✗ NON-LINEARIZABLE` + exit 1。
///
/// `docs/exit-codes.md` 明确要求这两种情形给出不同退出码（`1` 是有效结论，
/// `3` 是没有结论），所以类型上必须分开。
pub(all) enum MinimizeOutcome {
  /// 历史线性一致，不存在反例
  Consistent
  /// 历史违规，且找到了最小见证
  MinViolation(Violation)
  /// 历史违规，但不存在满足下界与可解释性的见证
  NoWitness
  /// 未下结论（预算耗尽、响应证据不完整或区间非法）
  Inconclusive(String)
}

///|
/// 见证的 `depth`：只能用**这份见证**的复核结果（2026-11-17 审计 LC-9）。
///
/// `Violation.depth` 的文档含义是「搜索过程中最后一致的前缀长度」，量纲绑定在
/// **被搜索的那份历史**上。旧实现在复核没有结论时回落成 `v.depth`——那是
/// **原历史**（通常更大）的数字，贴到见证上就会多报前缀：`noisy_bad` 的
/// check 给出 depth=3 / 见证 4 条，最小化压到 2 条；一旦复核超时，旧实现会把
/// 「3」写到一条 2 条操作的见证上（`--json` 的 `depth` 字段与
/// `render_violation` 的「最长一致前缀长度」都直接展示它）。
///
/// depth 还参与 `violation_reason` 的 data-inconsistency 判据
/// （`depth == 0 && ops.length() == 1`），所以口径错会连带改分类。
///
/// 复核没有结论（`Unknown`）或见证已不能复现违规（`Linearizable`）时如实返回
/// `0`：不声明任何前缀。宁可少说一句，也不借用另一份历史的数字——
/// 见证**仍然违规**这件事由 `witness_ok` 独立验证过，这里降级的只是
/// 「前缀有多长」这一条修饰信息。
fn[M : Model] witness_depth(
  minimal : Array[Operation],
  model : M,
  config : CheckConfig,
) -> Int32 {
  match probe_ops(minimal, model, config) {
    Violation(v2) => v2.depth
    _ => 0
  }
}

///|
/// 违规见证的可空版本：`None` = 历史违规，但不存在满足下界与可解释性的见证。
///
/// `min_witness <= 0` 时走**无守卫**路径（纯 ddmin，允许压到 1 条操作），
/// 保留 `minimize_raw` 的既有语义（教学 / 对照用）。
fn[M : Model] minimize_outcome_opt(
  history : History,
  model : M,
  config : CheckConfig,
  min_witness : Int32,
) -> MinimizeOutcome {
  let original_n = history.length()
  let outcome = check_with(history, model, config)
  match outcome {
    Linearizable => Consistent
    // 未下结论时不构造任何「见证」——原样交给调用方，由它决定退出码。
    Unknown(reason) => Inconclusive(reason)
    Violation(v) => {
      let seed = seed_of(history, v)
      if min_witness <= 0 {
        // 纯 ddmin：显式请求「不要守卫」，允许单个操作作见证。
        let minimal = ddmin_bounded(seed, model, config, 200, 0, None)
        let depth = witness_depth(minimal, model, config)
        MinViolation(Violation::{
          ops: sort_ops_by_id(minimal),
          depth,
          explanation: explain_minimal(
            original_n, minimal, "delta debugging", model, config,
          ),
        })
      } else {
        let expl = Expl::new()
        let unknown : Array[String] = []
        match
          minimal_witness_trace(
            seed,
            history.operations,
            model,
            config,
            min_witness,
            expl,
            unknown,
          ) {
          Some(minimal) => {
            let depth = witness_depth(minimal, model, config)
            MinViolation(Violation::{
              ops: sort_ops_by_id(minimal),
              depth,
              explanation: explain_minimal(
                original_n, minimal, "delta debugging", model, config,
              ),
            })
          }
          None =>
            if unknown.length() > 0 {
              // 没找到见证的证据本身不完整：只能说最小化未完成，不能声称
              // 满足约束的见证不存在。首轮 Violation 仍然成立，但这里描述的是
              // 最小化搜索的状态，不是把原历史改判成 Linearizable。
              Inconclusive(unknown[0])
            } else {
              NoWitness
            }
        }
      }
    }
  }
}

///|
/// 旧 `Violation?` 入口的适配层（保留既有语义，供 `minimize_with` 等使用）。
///
/// `Inconclusive` 仍然映射成「全部操作 + 如实说明」的载体，因为
/// `API.md` §4 把这条文本行为写进了 `minimize` 的契约（`unknown_results_test`
/// 也锁定它）。需要**区分**「未下结论」与「已判定违规 / 无见证」的调用方
/// 必须改用 `minimize_outcome`。
fn[M : Model] minimize_opt(
  history : History,
  model : M,
  config : CheckConfig,
  min_witness : Int32,
) -> Violation? {
  match minimize_outcome_opt(history, model, config, min_witness) {
    Consistent =>
      Some(Violation::{
        ops: [],
        depth: 0,
        explanation: "历史线性一致，不存在反例。",
      })
    MinViolation(v) => Some(v)
    NoWitness => None
    Inconclusive(reason) =>
      Some(
        no_witness(
          history.operations,
          "检查未能给出结论（\{reason}），无法最小化；返回全部操作供人工查看。",
        ),
      )
  }
}

///|
/// 对违规历史做 delta-debugging，得到最小子集（泛型实现）
pub fn[M : Model] minimize_with(
  history : History,
  model : M,
  config : CheckConfig,
) -> Violation {
  minimize_with_bound(history, model, config, MIN_WITNESS)
}

///|
/// 同上，可指定见证下界（`<= 0` 表示允许压到单个操作）
pub fn[M : Model] minimize_with_bound(
  history : History,
  model : M,
  config : CheckConfig,
  min_witness : Int32,
) -> Violation {
  match minimize_opt(history, model, config, min_witness) {
    Some(v) => v
    None =>
      no_witness(
        history.operations,
        no_explainable_witness_text(history.length(), min_witness),
      )
  }
}

///|
/// 按进程分组 + 逐操作的最小化实现。配置注入仅供内部复用与低成本测试；
/// 公开入口始终传 `CheckConfig::default()`，公开 API 与行为不变。
fn[M : Model] minimize_by_process_opt_with_config(
  history : History,
  model : M,
  config : CheckConfig,
  min_witness : Int32,
) -> Violation? {
  let original_n = history.length()
  let outcome = check_with(history, model, config)
  match outcome {
    Linearizable =>
      Some(Violation::{
        ops: [],
        depth: 0,
        explanation: "历史线性一致，不存在反例。",
      })
    Unknown(reason) =>
      Some(
        no_witness(
          history.operations,
          "检查未能给出结论（\{reason}），无法最小化；返回全部操作供人工查看。",
        ),
      )
    Violation(v) => {
      let seed = seed_of(history, v)
      let expl = Expl::new()
      let unknown : Array[String] = []
      // 第一步：收集出现过的进程号（升序，保证确定性）
      //
      // 旧写法是对每个见证操作线性扫一遍「已见进程号」，O(操作数 × 进程数)；
      // 与 `visualize` / `process_ids` 同一处 O(n·P)（2026-11-21 审计 LC-24）。
      // 下面「逐个进程整块砍掉」的循环必须保留逐次扫描：它砍的是**正在收缩**
      // 的 `current`，而不是固定的种子，语义不同。
      let (procs, _) = group_by_process(seed)
      // 第二步：逐个进程整块砍掉
      let mut current = seed.copy()
      for p in procs {
        let rest : Array[Operation] = []
        for op in current {
          if op.process != p {
            rest.push(op)
          }
        }
        if candidate_accepted_trace(
            current,
            rest,
            model,
            config,
            min_witness,
            Some(expl),
            unknown,
          ) {
          current = rest
        }
      }
      // 第三步：逐操作细粒度砍（种子不合格时以整份历史为起点重新找见证）
      let witness = minimal_witness_trace(
        current,
        history.operations,
        model,
        config,
        min_witness,
        expl,
        unknown,
      )
      match witness {
        None =>
          if unknown.length() > 0 {
            Some(
              no_witness(
                history.operations,
                "检查未能给出结论（\{unknown[0]}），无法最小化；返回全部操作供人工查看。",
              ),
            )
          } else {
            None
          }
        Some(minimal) => {
          let depth = witness_depth(minimal, model, config)
          Some(Violation::{
            ops: sort_ops_by_id(minimal),
            depth,
            explanation: explain_minimal(
              original_n, minimal, "按进程 + 逐操作最小化", model, config,
            ),
          })
        }
      }
    }
  }
}

///|
/// 按进程分组 + 逐操作的最小化（泛型版，`None` = 找不到合格见证）。
pub fn[M : Model] minimize_by_process_opt(
  history : History,
  model : M,
  min_witness : Int32,
) -> Violation? {
  minimize_by_process_opt_with_config(
    history,
    model,
    CheckConfig::default(),
    min_witness,
  )
}

///|
/// 按进程分组的最小化：先整进程砍，再逐操作砍（常能显著缩小）
pub fn[M : Model] minimize_by_process_with(
  history : History,
  model : M,
  min_witness : Int32,
) -> Violation {
  match minimize_by_process_opt(history, model, min_witness) {
    Some(v) => v
    None =>
      no_witness(
        history.operations,
        no_explainable_witness_text(history.length(), min_witness),
      )
  }
}

///|
/// 对违规历史做 delta-debugging，得到最小子集（对外入口）
pub fn minimize(
  history : History,
  model : AnyModel,
  config : CheckConfig,
) -> Violation {
  minimize_with(history, model, config)
}

///|
/// 最小见证（可空入口）：`None` = 历史违规但不存在满足下界与可解释性的见证。
///
/// CLI 用它区分「最小化：N → M」与「N 个操作里找不到可输出的见证」。
///
/// **注意**：这个签名无法表达「未下结论」——预算耗尽时它同样返回
/// `Some(Violation{ ops: 全部操作, ... })`（历史行为，被 `unknown_results_test`
/// 锁定）。需要按退出码区分三态的命令行 / 脚本请用 `minimize_outcome`。
pub fn minimize_witness(
  history : History,
  model : AnyModel,
  config : CheckConfig,
) -> Violation? {
  minimize_opt(history, model, config, MIN_WITNESS)
}

///|
/// 最小化的四态入口（对外）：`Consistent` / `MinViolation` /
/// `NoWitness` / `Inconclusive`。
///
/// 这是唯一能把「没下结论」与「已判定违规」分开的入口。CLI 的 `minimize`
/// 必须用它，否则 `docs/exit-codes.md` 要求的 `1` / `3` 之分会丢失。
pub fn minimize_outcome(
  history : History,
  model : AnyModel,
  config : CheckConfig,
) -> MinimizeOutcome {
  match model {
    Register(m) => minimize_outcome_opt(history, m, config, MIN_WITNESS)
    Counter(m) => minimize_outcome_opt(history, m, config, MIN_WITNESS)
    Set(m) => minimize_outcome_opt(history, m, config, MIN_WITNESS)
    Queue(m) => minimize_outcome_opt(history, m, config, MIN_WITNESS)
  }
}

///|
/// 按进程分组的最小化（对外入口）
pub fn minimize_by_process(history : History, model : AnyModel) -> Violation {
  minimize_by_process_with(history, model, MIN_WITNESS)
}

///|
/// 纯 ddmin：允许压到单个操作（对照 / 教学用）
pub fn minimize_raw(
  history : History,
  model : AnyModel,
  config : CheckConfig,
) -> Violation {
  minimize_with_bound(history, model, config, 0)
}
