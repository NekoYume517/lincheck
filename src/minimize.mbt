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
/// 带守卫的压缩：压不动就原样返回种子
pub fn[M : Model] shrink(
  seed : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl,
) -> Array[Operation] {
  let result = ddmin_bounded(seed, model, config, 200, min_witness, Some(expl))
  let big_enough = result.length() >= min_witness
  if big_enough && still_violates(result, model, config) {
    result
    // 原始历史本身就小于下界（例如只有一条不可解释的读），不做裁剪。
    // 但**兜底前必须确认种子本身仍违规**（L2 加固）：ddmin 的输入来自
    // check 的反例，若上游证据链有缺陷（如 ops 里不含肇事操作），seed
    // 可能线性一致 —— 此时静默返回它会产生一个 check 都否定的「见证」。
    // 宁可 panic 也不输出自相矛盾的结果。
  } else if still_violates(seed, model, config) {
    seed.copy()
  } else {
    abort("minimize: seed history is linearizable; witness chain is broken")
  }
}

///|
/// 按 id 升序排序（见证子集要求稳定输出）
pub fn sort_ops_by_id(ops : Array[Operation]) -> Array[Operation] {
  let out = ops.copy()
  out.sort_by(fn(a, b) { a.id - b.id })
  out
}

///|
/// 拼一段人类可读的说明
fn explain_minimal(
  original_n : Int32,
  ops : Array[Operation],
  prefix : String,
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
  sb.write_string(
    "删掉其中任何一个操作，历史都会变回线性一致。",
  )
  sb.to_string()
}

///|
/// 统一构造「没有见证」的结果
fn no_witness(ops : Array[Operation], text : String) -> Violation {
  Violation::{ ops: sort_ops_by_id(ops), depth: 0, explanation: text, }
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
/// 对违规历史做 delta-debugging，得到最小子集（泛型实现）
pub fn[M : Model] minimize_with(
  history : History,
  model : M,
  config : CheckConfig,
) -> Violation {
  minimize_with_bound(history, model, config, MIN_WITNESS)
}

///|
/// 同上，可指定见证下界（0 表示允许压到单个操作）
pub fn[M : Model] minimize_with_bound(
  history : History,
  model : M,
  config : CheckConfig,
  min_witness : Int32,
) -> Violation {
  let original_n = history.length()
  let outcome = check_with(history, model, config)
  match outcome {
    Linearizable =>
      Violation::{
        ops: [],
        depth: 0,
        explanation: "历史线性一致，不存在反例。",
      }
    Unknown(reason) =>
      no_witness(
        history.operations,
        "检查未能给出结论（\{reason}），无法最小化；返回全部操作供人工查看。",
      )
    Violation(v) => {
      let expl = Expl::new()
      let minimal = shrink(
        seed_of(history, v),
        model,
        config,
        min_witness,
        expl,
      )
      let depth = match probe_ops(minimal, model, config) {
        Violation(v2) => v2.depth
        _ => v.depth
      }
      Violation::{
        ops: sort_ops_by_id(minimal),
        depth,
        explanation: explain_minimal(original_n, minimal, "delta debugging"),
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
  let config = CheckConfig::default()
  let original_n = history.length()
  let outcome = check_with(history, model, config)
  match outcome {
    Linearizable =>
      Violation::{
        ops: [],
        depth: 0,
        explanation: "历史线性一致，不存在反例。",
      }
    Unknown(reason) =>
      no_witness(
        history.operations,
        "检查未能给出结论（\{reason}），无法最小化；返回全部操作供人工查看。",
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
      // 第三步：逐操作细粒度砍
      let minimal = shrink(current, model, config, min_witness, expl)
      let depth = match probe_ops(minimal, model, config) {
        Violation(v2) => v2.depth
        _ => v.depth
      }
      Violation::{
        ops: sort_ops_by_id(minimal),
        depth,
        explanation: explain_minimal(
          original_n, minimal, "按进程 + 逐操作最小化",
        ),
      }
    }
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
