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
/// 判断子集是否仍违规（唯一判定依据）
pub fn[M : Model] still_violates(
  ops : Array[Operation],
  model : M,
  config : CheckConfig,
) -> Bool {
  let outcome = probe_ops(ops, model, config)
  match outcome {
    Violation(_) => true
    _ => false
  }
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
/// 单个操作是否孤立非法（带缓存）
pub fn[M : Model] Expl::is_illegal(
  self : Expl,
  op : Operation,
  model : M,
  config : CheckConfig,
) -> Bool {
  let key = op_key(op)
  match self.illegal.get(key) {
    Some(v) => v
    None => {
      let single : Array[Operation] = [op]
      let v = match probe_ops(single, model, config) {
        Violation(_) => true
        _ => false
      }
      self.illegal[key] = v
      v
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
  // 无序对：按指纹字典序拼接，保证 (a,b) 与 (b,a) 命中同一缓存槽
  let ka = op_key(a)
  let kb = op_key(b)
  let key = if ka < kb { "\{ka}|\{kb}" } else { "\{kb}|\{ka}" }
  match self.pairs.get(key) {
    Some(v) => v
    None => {
      let pair : Array[Operation] = [a, b]
      match probe_ops(pair, model, config) {
        Unknown(_) => false
        outcome => {
          let v = outcome is Linearizable
          self.pairs[key] = v
          v
        }
      }
    }
  }
}

///|
/// 候选子集是否满足可解释性约束：
/// 每个「孤立非法」的操作，都必须有一个同伴能把它解释掉。
///
/// 「排除自己」用**数组下标**而非 `op.id`：同 id 的不同操作是真正的同伴，
/// 按 id 排除会把它们当自己而漏掉解释者。
pub fn[M : Model] explainable(
  subset : Array[Operation],
  model : M,
  config : CheckConfig,
  expl : Expl,
) -> Bool {
  for i, op in subset {
    if expl.is_illegal(op, model, config) {
      let mut explained = false
      for j, other in subset {
        if j != i && expl.pair_explains(op, other, model, config) {
          explained = true
        }
      }
      if !explained {
        return false
      }
    }
  }
  true
}

///|
/// 单次候选判定：够大 + 更小 + 仍违规 + （可选）可解释
pub fn[M : Model] candidate_accepted(
  current : Array[Operation],
  candidate : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl?,
) -> Bool {
  let big_enough = candidate.length() >= min_witness
  let smaller = candidate.length() < current.length()
  if !big_enough || !smaller {
    return false
  }
  if !still_violates(candidate, model, config) {
    return false
  }
  match expl {
    Some(e) => explainable(candidate, model, config, e)
    None => true
  }
}

///|
/// delta debugging 主体。
///
/// min_witness 是最小操作数下界；expl 为 None 时退化成经典 ddmin。
pub fn[M : Model] ddmin_bounded(
  initial : Array[Operation],
  model : M,
  config : CheckConfig,
  max_rounds : Int32,
  min_witness : Int32,
  expl : Expl?,
) -> Array[Operation] {
  let mut current = initial.copy()
  let mut rounds = 0
  let mut improved = true
  while improved && rounds < max_rounds {
    improved = false
    rounds = rounds + 1
    let mut chunk = current.length() / 2
    while chunk >= 1 {
      let mut i = 0
      let mut found = false
      while i < current.length() && !found {
        let candidate = remove_chunk(current, i, chunk)
        if candidate_accepted(
            current, candidate, model, config, min_witness, expl,
          ) {
          current = candidate
          found = true
        }
        i = i + chunk
      }
      if found {
        improved = true
        chunk = 0 // 跳出内层，重新从 len/2 开始
      } else {
        chunk = chunk / 2
      }
    }
  }
  current
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
) -> Bool {
  if cand.length() < min_witness {
    return false
  }
  if !still_violates(cand, model, config) {
    return false
  }
  explainable(cand, model, config, expl)
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
    if witness_ok(cand, model, config, min_witness, expl) {
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
pub fn[M : Model] minimal_witness(
  seed : Array[Operation],
  pool : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl,
) -> Array[Operation]? {
  let from_seed = ddmin_bounded(
    seed,
    model,
    config,
    200,
    min_witness,
    Some(expl),
  )
  if witness_ok(from_seed, model, config, min_witness, expl) {
    return Some(from_seed)
  }
  if min_witness <= 2 {
    match first_ok_subset(pool, model, config, min_witness, expl, 2, 48) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  if min_witness <= 3 {
    match first_ok_subset(pool, model, config, min_witness, expl, 3, 14) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  let from_pool = ddmin_bounded(
    pool,
    model,
    config,
    200,
    min_witness,
    Some(expl),
  )
  if witness_ok(from_pool, model, config, min_witness, expl) {
    return Some(from_pool)
  }
  None
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
  // 逐条复验：删掉第 i 条后是否仍违规（i 用下标，同 id 操作各自可删）
  let mut any_remains = false
  for i, _ in ops {
    if still_violates(remove_chunk(ops, i, 1), model, config) {
      any_remains = true
    }
  }
  if any_remains {
    sb.write_string(
      "在最少保留这么多个操作的约束下无法继续缩减：存在删掉某一条后仍违规的方向，但继续缩减会跌破最小见证下界或破坏可解释性。",
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
  " 个操作供人工查看——这通常意味着历史数据自相矛盾（例如初值 0 上记录了 CAS 返回 true），" +
  "而不是并发交错导致的竞态。"
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
/// 违规见证的可空版本：`None` = 历史违规，但不存在满足下界与可解释性的见证。
///
/// `min_witness <= 0` 时走**无守卫**路径（纯 ddmin，允许压到 1 条操作），
/// 保留 `minimize_raw` 的既有语义（教学 / 对照用）。
fn[M : Model] minimize_opt(
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
      if min_witness <= 0 {
        // 纯 ddmin：显式请求「不要守卫」，允许单个操作作见证。
        let minimal = ddmin_bounded(seed, model, config, 200, 0, None)
        let depth = match probe_ops(minimal, model, config) {
          Violation(v2) => v2.depth
          _ => v.depth
        }
        Some(Violation::{
          ops: sort_ops_by_id(minimal),
          depth,
          explanation: explain_minimal(
            original_n, minimal, "delta debugging", model, config,
          ),
        })
      } else {
        let expl = Expl::new()
        match
          minimal_witness(
            seed,
            history.operations,
            model,
            config,
            min_witness,
            expl,
          ) {
          Some(minimal) => {
            let depth = match probe_ops(minimal, model, config) {
              Violation(v2) => v2.depth
              _ => v.depth
            }
            Some(Violation::{
              ops: sort_ops_by_id(minimal),
              depth,
              explanation: explain_minimal(
                original_n, minimal, "delta debugging", model, config,
              ),
            })
          }
          None => None
        }
      }
    }
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
/// 按进程分组 + 逐操作的最小化（泛型版，`None` = 找不到合格见证）
pub fn[M : Model] minimize_by_process_opt(
  history : History,
  model : M,
  min_witness : Int32,
) -> Violation? {
  let config = CheckConfig::default()
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
      // 第一步：收集出现过的进程号（升序，保证确定性）
      let procs : Array[Int32] = []
      for op in seed {
        let mut seen = false
        for p in procs {
          if p == op.process {
            seen = true
          }
        }
        if !seen {
          procs.push(op.process)
        }
      }
      procs.sort()
      // 第二步：逐个进程整块砍掉
      let mut current = seed.copy()
      for p in procs {
        let rest : Array[Operation] = []
        for op in current {
          if op.process != p {
            rest.push(op)
          }
        }
        if candidate_accepted(
            current,
            rest,
            model,
            config,
            min_witness,
            Some(expl),
          ) {
          current = rest
        }
      }
      // 第三步：逐操作细粒度砍（种子不合格时以整份历史为起点重新找见证）
      let witness = minimal_witness(
        current,
        history.operations,
        model,
        config,
        min_witness,
        expl,
      )
      match witness {
        None => None
        Some(minimal) => {
          let depth = match probe_ops(minimal, model, config) {
            Violation(v2) => v2.depth
            _ => v.depth
          }
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
pub fn minimize_witness(
  history : History,
  model : AnyModel,
  config : CheckConfig,
) -> Violation? {
  minimize_opt(history, model, config, MIN_WITNESS)
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
