// ============================================================================
// lincheck CLI
//
//   lincheck check     --history <f.jsonl> --model <m> [--budget-ms N] [--json]
//   lincheck minimize  --history <f.jsonl> --model <m> [--json]
//   lincheck visualize --history <f.jsonl>
//   lincheck gen       --model <m> --processes N --ops N --seed N [--consistent|--random|--inject]
//   lincheck selfcheck --model <m> --seeds N [--ops N] [--processes N]
//
// 退出码：0 一致 / 1 违规 / 2 用法错误 / 3 未知
//
// 注：跨包符号必须写全 `@lib.` 前缀——MoonBit 不会自动展开 src 包的导出。
// ============================================================================

///|
/// 退出码
const EXIT_OK : Int32 = 0

///|
const EXIT_VIOLATION : Int32 = 1

///|
const EXIT_USAGE : Int32 = 2

///|
const EXIT_UNKNOWN : Int32 = 3

///|
/// 输入数据错误（文件读不到、JSONL 不合法）。
/// 不复用 1 —— 1 专指「发现违规」，混用会让脚本无法区分
/// 「历史确实违规」和「历史文件根本读不了」。
const EXIT_DATA : Int32 = 4

///|
/// CLI 用法错误（参数缺失、拼错、未知取值）
suberror Failure {
  Failure(String)
}

///|
/// 输入数据错误（文件读不到、JSONL 不合法、记录格式错）
///
/// 与 `Failure` 分开，是为了让退出码能区分「你命令打错了」和
/// 「你的数据有问题」——这两件事调用方的处理方式完全不同。
suberror DataFailure {
  DataFailure(String)
}

///|
/// 解析后的一次调用
struct Cli {
  command : String
  model : String
  history_path : String
  budget_ms : Int32
  seeds : Int32
  processes : Int32
  ops_per_process : Int32
  seed : Int32
  concurrency : Double
  mode : String
  json : Bool
  /// 命令行上**实际出现过**的参数名（按出现顺序，重复不去重）。
  ///
  /// 白名单校验（`validate_flags`）要用它：只凭字段值分不清「用户显式写了
  /// `--budget-ms 5000`」和「用户没写、默认值恰好也是 5000」——而这两件事在
  /// 「本子命令不接受该参数」的报错里必须区分。
  used : Array[String]
}

///|
fn default_cli(cmd : String) -> Cli {
  {
    command: cmd,
    model: "register",
    history_path: "",
    budget_ms: 5000,
    seeds: 100,
    processes: 3,
    ops_per_process: 4,
    seed: 1,
    concurrency: 0.5,
    mode: "consistent",
    json: false,
    used: [],
  }
}

// ── 参数解析 ──────────────────────────────────────────────────────────

///|
/// 解析整数（允许前导 -）。手写逐位累加，不依赖标准库解析函数。
///
/// 溢出防护：累加前先判断 `acc` 是否还会溢出（Int32 上限 2147483647），
/// 溢出返回 None 让调用方报「参数值非法」，而不是静默回绕成另一个数。
/// `-2147483648` 单独放行：它的绝对值超 Int32 上限，但取负后合法。
///
/// 标 `pub` 仅为可测性：可执行包没有下游消费者，黑盒测试（主包的
/// `*_test.mbt` 只能看到 pub 符号）需要直接覆盖溢出与符号的边界。
pub fn parse_int_arg(s : String) -> Int32? {
  if s.length() == 0 {
    return None
  }
  let mut body = s
  let mut neg = false
  if s[0] == '-' {
    neg = true
    body = s.substring(start=1, end=s.length())
  }
  if body.length() == 0 {
    return None
  }
  if neg && body == "2147483648" {
    // 唯一绝对值超 Int32 上限的合法负数：整个数字串恰为 2147483648。
    // 必须在累加循环之前放行——循环内的溢出检查会先把它拒成 None，
    // 旧实现对此的放行写在循环之后，实际永远到不了。
    return Some(-2147483648)
  }
  // Int32 上限 2147483647：累加前判断 acc 是否还会溢出，溢出返回 None
  // 让调用方报「参数值非法」，而不是静默回绕成另一个数。
  let mut acc = 0
  for ch in body.to_array() {
    if !ch.is_ascii_digit() {
      return None
    }
    let d = ch.to_int() - '0'.to_int()
    if acc > (2147483647 - d) / 10 {
      return None
    }
    acc = acc * 10 + d
  }
  if neg {
    Some(-acc)
  } else {
    Some(acc)
  }
}

///|
/// 一串**无符号**十进制数字（非空）。
///
/// `parse_double_arg` 的两段（整数段、小数段）都必须满足它：符号只允许出现在
/// 整个数值的最前面，段内出现符号不是"可以忽略的前缀"，而是非法输入。
fn is_ascii_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  let mut ok = true
  let mut i = 0
  while i < s.length() {
    let c = s[i]
    if c < '0' || c > '9' {
      ok = false
    }
    i = i + 1
  }
  ok
}

///|
/// 一段无符号十进制数字 → `Int64?`（溢出返回 `None`）。
///
/// 存在的理由：`parse_double_arg` 的两段原本都走 `parse_int_arg`（Int32），
/// 于是「位数多」被当成「参数值非法」（2026-11-17-b 审计 LC-15：
/// `--concurrency 0.3000000000` 判 exit 2，而 `0.3000000000` 就是 `0.3`）。
/// 容量是实现细节，不该出现在语法判据里。
fn parse_unsigned_int64(s : String) -> Int64? {
  if s.length() == 0 {
    return None
  }
  let mut acc : Int64 = 0L
  for ch in s.to_array() {
    if !ch.is_ascii_digit() {
      return None
    }
    let d = (ch.to_int() - '0'.to_int()).to_int64()
    if acc > (9223372036854775807L - d) / 10L {
      return None
    }
    acc = acc * 10L + d
  }
  Some(acc)
}

///|
/// 小数段参与计算的位数上界。
///
/// `Double` 在 `[0, 1]` 上的分辨率约 1e-16，第 `MAX_FRACTION_DIGITS` 位之后
/// 的数字既不可能改变最终值、也不可能改变「是否落在 `[0, 1]` 域内」的判定
/// （这一点对 `1.000…` 与 `0.999…` 两端同样成立：截断后的值仍在原值同侧，
/// 且与正确舍入的 Double 相差不超过 1 ulp）。所以长尾小数**截断**而不是
/// 报用法错误——位数不是用户该操心的事（LC-15）。
const MAX_FRACTION_DIGITS : Int32 = 18

///|
/// 解析 "0.5" / "1" 这类简单浮点。
///
/// 语法只有一种：`'-'? digits ('.' digits)?`。符号必须对整个数值生效，
/// **每一段都必须是无符号数字**。
///
/// 三条历史教训：
/// - 早期把负号塞给整数段，`-0.5` 变成 `+0.5`、`-1.5` 变成 `-0.5`；
/// - 把两段分别喂给带符号的 `parse_int_arg` 时，符号还能出现在段内：
///   `1.-5` = 1 + (-5)/100 = **0.95**、`0.-1` = **-0.01**（看着正数解析出负数）、
///   `--1.5` = **0.5**（两层负号互相抵消）。这些都不是可接受的输入，
///   调用方必须能靠 `None` 报用法错误，而不是拿到一个被悄悄换过的数值。
/// - 两段都按 **Int32** 解析过：`0.3000000000`（`0.3` 的另一种写法）、
///   `0.12345678901`、`2147483648` 都被判成「参数值非法」——判据变成了
///   Int32 容量而不是语法（LC-15）。现在两段按 Int64 累加，小数段超过
///   `MAX_FRACTION_DIGITS` 位时截断。
///
/// 标 `pub` 仅为可测性，理由同 parse_int_arg。
pub fn parse_double_arg(s : String) -> Double? {
  let mut body = s
  let mut neg = false
  if body.length() > 0 && body[0] == '-' {
    neg = true
    body = body.substring(start=1, end=body.length())
  }
  let parts = body.split(".").collect()
  if parts.length() == 1 {
    let whole_s = parts[0].to_owned()
    if !is_ascii_digits(whole_s) {
      return None
    }
    match parse_unsigned_int64(whole_s) {
      Some(v) => if neg { Some(-v.to_double()) } else { Some(v.to_double()) }
      None => None
    }
  } else if parts.length() == 2 {
    let whole_s = parts[0].to_owned()
    let frac_s = parts[1].to_owned()
    // 两段都是纯数字：`1.-5` / `0.-1` / `--1.5` 在这里被拒。
    if !is_ascii_digits(whole_s) || !is_ascii_digits(frac_s) {
      return None
    }
    let whole = match parse_unsigned_int64(whole_s) {
      Some(v) => v
      None => return None
    }
    // 只取前 MAX_FRACTION_DIGITS 位参与计算（见常量注释：更远的位对
    // Double 与域判定都没有影响），scale 也按截断后的位数取。
    let used = if frac_s.length() > MAX_FRACTION_DIGITS {
      MAX_FRACTION_DIGITS
    } else {
      frac_s.length()
    }
    let frac_head = frac_s.substring(start=0, end=used)
    let frac = match parse_unsigned_int64(frac_head) {
      Some(v) => v
      None => return None
    }
    let mut scale = 1.0
    let mut i = 0
    while i < used {
      scale = scale * 10.0
      i = i + 1
    }
    let value = whole.to_double() + frac.to_double() / scale
    if neg {
      Some(-value)
    } else {
      Some(value)
    }
  } else {
    None
  }
}

///|
/// 打印用法
fn usage() -> Unit {
  println("lincheck — 线性一致性检查器")
  println("")
  println("用法：")
  println(
    "  lincheck check     --history <file.jsonl> --model <m> [--budget-ms N] [--json]",
  )
  println("  lincheck minimize  --history <file.jsonl> --model <m> [--json]")
  println("  lincheck visualize --history <file.jsonl>")
  println(
    "  lincheck gen       --model <m> --processes N --ops N --seed N [--consistent|--random|--inject] [--concurrency F]",
  )
  println(
    "  lincheck selfcheck --model <m> --seeds N [--ops N] [--processes N]",
  )
  println("")
  let names = StringBuilder()
  for i, n in @lib.model_names() {
    if i > 0 {
      names.write_string(" | ")
    }
    names.write_string(n)
  }
  println("模型：\{names.to_string()}")
  println("")
  println(
    "退出码：0 线性一致 / 1 发现违规 / 2 用法错误 / 3 结论未知 / 4 输入数据错误",
  )
}

// ── 载入历史 ──────────────────────────────────────────────────────────

///|
/// 把解析失败渲染成可读的错误文本（**行号 + 原因**都在里面）。
///
/// 库层的 `History::from_jsonl` 已经算好了「从 1 开始的行号」与具体原因
/// （见 `history.mbt` 的 `parse_op_line`，注释写明「报错位置与编辑器里的行号
/// 一致」），旧实现却用 `Err(_)` 把它们整个丢掉，只留一句
/// `JSONL 解析失败：<路径>` —— 对一个几百行的历史几乎无法定位。
///
/// 标 `pub` 仅为可测性（理由同 `parse_int_arg`）：错误文本是这条命令的
/// 可观测输出，主包的 `*_test.mbt` 只能看到 pub 符号。返回 `String` 而不是
/// 直接 raise，是为了让测试能无副作用地断言文本。
pub fn jsonl_error_text(path : String, error : Error) -> String {
  match error {
    @lib.BadLine(line_no, reason) =>
      "JSONL 解析失败：\{path}（第 \{line_no} 行：\{reason}）"
    _ => "JSONL 解析失败：\{path}"
  }
}

///|
fn load_history(path : String) -> @lib.History raise {
  if path.length() == 0 {
    raise Failure("缺少 --history")
  }
  let text : String = @fs.read_file_to_string(path) catch {
    _ => raise DataFailure("读不到文件：\{path}")
  }
  match @lib.History::from_jsonl(text) {
    Ok(h) => h
    Err(e) => raise DataFailure(jsonl_error_text(path, e))
  }
}

// ── check ─────────────────────────────────────────────────────────────

///|
/// 违规结果的 JSON 形态
fn json_violation(
  v : @lib.Violation,
  history : @lib.History,
  verdict : String,
) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"verdict\":\"")
  sb.write_string(verdict)
  // 可编程区分「真并发违规」与「历史数据自相矛盾」：两者退出码都是 1，
  // 光看 verdict 分不出来（LC-2）。见证没能被复现时如实写 unconfirmed-witness。
  sb.write_string("\",\"reason\":\"")
  sb.write_string(
    if verdict == "non-linearizable" {
      @lib.violation_reason(v)
    } else {
      "unconfirmed-witness"
    },
  )
  sb.write_string("\",\"total\":")
  sb.write_string(history.length().to_string())
  sb.write_string(",\"witness\":[")
  for i, op in v.ops {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("{\"id\":")
    sb.write_string(op.id.to_string())
    sb.write_string(",\"process\":")
    sb.write_string(op.process.to_string())
    sb.write_string(",\"op\":\"")
    sb.write_string(@lib.kind_label(op.kind))
    sb.write_string("\",\"result\":\"")
    sb.write_string(@lib.result_label(op.result))
    sb.write_string("\",\"start\":")
    sb.write_string(op.start.to_string())
    sb.write_string(",\"end\":")
    sb.write_string(op.end.to_string())
    sb.write_string("}")
  }
  sb.write_string("],\"depth\":")
  sb.write_string(v.depth.to_string())
  sb.write_string("}")
  sb.to_string()
}

///|
/// 「线性一致」的 JSON 形状（`check` 与 `minimize` 共用一份）。
///
/// 收敛到一个构造器是为了让**同一个量在整条 CLI 里只有一个键名**：历史操作数
/// 在违规形状里叫 `total`（`json_violation`），在 linearizable 形状里曾叫 `ops`
/// —— 同一条命令的两个分支对同一个数字用两个名字，脚本按 `jq .total` 取值时
/// 会在「历史合法」这一支上拿到 null（2026-11-17-b 第二轮 LC-16）。
fn linearizable_json(total : Int32) -> String {
  "{\"verdict\":\"linearizable\",\"total\":" + total.to_string() + "}"
}

///|
/// 「没有结论」的 JSON 形状（`check` / `minimize` 三处共用一份）。
///
/// `reason` 在两种 verdict 下承载**同一个语义槽**（「为什么是这个结论」），
/// 但取值域不同：违规形状是分类 token（`data-inconsistency` /
/// `concurrency-race` / `unconfirmed-witness`），这里是一句散文（预算耗尽多少
/// 毫秒 / 几个 Nil / 哪个操作区间非法）。这是刻意的：分类要能被程序分支，
/// 散文要能被人读懂。语义写在 `API.md` §7.1，并由
/// `cmd/lincheck/json_shape_wbtest.mbt` 逐字节锁住（2026-11-17-b 第二轮 LC-18）。
fn unknown_json(reason : String) -> String {
  "{\"verdict\":\"unknown\",\"reason\":\"" + reason + "\"}"
}

///|
/// 「违规但找不到可解释见证」的 JSON 形状（`minimize` 专用）。
///
/// 这个形状**没有 `depth`**，而且不该有：`depth` 的定义是「该见证的最长一致
/// 前缀长度」（`Violation.depth`），这里根本没有见证（`witness` 是空数组）。
/// 补一个 `depth: 0` 会把「没有见证」写成「有见证且前缀为空」—— 后者正是
/// `violation_reason` 里 data-inconsistency 的判据，两种结论不是一回事。
/// 语义写在 `API.md` §7.1，缺席本身由 `json_shape_wbtest.mbt` 锁住。
fn no_witness_json(total : Int32) -> String {
  "{\"verdict\":\"non-linearizable\",\"total\":" +
  total.to_string() +
  ",\"witness\":[],\"reason\":\"no-explainable-witness\"}"
}

///|
/// 解析 `--model`，未知名字返回可读的错误消息。
///
/// 不静默回退到默认模型：拼错一个字母就静默换模型，会给出一个看起来
/// 权威但完全不对的结论。
fn resolve_model(cli : Cli) -> Result[@lib.AnyModel, String] {
  match @lib.model_by_name(cli.model) {
    Some(m) => Ok(m)
    None =>
      Err(
        "未知模型 \{cli.model}（可选 \{@lib.model_names().join(", ")})",
      )
  }
}

///|
/// 解析模型，失败时打印到 stderr 并返回 None 供调用方提前退出。
fn require_model(cli : Cli) -> @lib.AnyModel? {
  match resolve_model(cli) {
    Ok(m) => Some(m)
    Err(msg) => {
      eprintln("用法错误: \{msg}")
      None
    }
  }
}

///|
fn cmd_check(cli : Cli) -> Int32 raise {
  let cfg = @lib.CheckConfig::{
    time_budget_ms: cli.budget_ms,
    max_states: 200000,
    allow_unknown_results: false,
  }
  // 先校验参数、再读数据：模型拼错 + 文件缺失同时存在时，
  // 应报「用法错误」(2) 而不是「数据错误」(4)——命令是你自己敲错的，
  // 修复动作是改命令行，不是修文件。
  let model = match require_model(cli) {
    Some(m) => m
    None => return EXIT_USAGE
  }
  let history = load_history(cli.history_path)
  match @lib.check(history, model, cfg) {
    @lib.Linearizable => {
      if cli.json {
        println(linearizable_json(history.length()))
      } else {
        println(
          "✓ LINEARIZABLE  (\{history.length()} 个操作，模型 \{cli.model})",
        )
      }
      EXIT_OK
    }
    @lib.Violation(v) => {
      if cli.json {
        println(json_violation(v, history, "non-linearizable"))
      } else {
        println(
          "✗ NON-LINEARIZABLE  (\{v.ops.length()} / \{history.length()} 个操作)",
        )
        println("")
        for op in v.ops {
          println("  \{@lib.op_line(op)}")
        }
        println("")
        println("  \{v.explanation}")
      }
      EXIT_VIOLATION
    }
    @lib.Unknown(reason) => {
      if cli.json {
        println(unknown_json(reason))
      } else {
        println("? UNKNOWN  \{reason}")
      }
      EXIT_UNKNOWN
    }
  }
}

// ── minimize ──────────────────────────────────────────────────────────

///|
/// `NoWitness` 结语：按**再查一次**的结论分流成因，三态必须透传。
///
/// - `Violation(v)`：`violation_reason(v)` 给出 `data-inconsistency` 或
///   `concurrency-race`，交给库层文案分流；
/// - 其余（`Unknown` / `Linearizable`）：成因**未定**，传 `"unknown"`。
///   这里绝不能兜底成 `concurrency-race`：那会把一次没跑完的检查编造成
///   「这是并发竞态」，正是 `docs/exit-codes.md` 三态哲学要避免的事
///   （同一主题上一轮已在单操作缓存、ddmin/witness、删除复验、by-process
///   四处修过，NoWitness 的成因分流是第五处）。
///
/// 标 `pub` 仅为可测性（理由同 `parse_int_arg`）：错误文本是这条命令的可观测
/// 输出，主包的 `*_test.mbt` 只能看到 pub 符号。
pub fn no_witness_reason_text(
  original_n : Int32,
  outcome : @lib.CheckOutcome,
) -> String {
  let reason = match outcome {
    @lib.Violation(v) => @lib.violation_reason(v)
    _ => "unknown"
  }
  @lib.no_explainable_witness_text_for(original_n, @lib.MIN_WITNESS, reason)
}

///|
/// 带缩进的操作列表
fn render_ops_indented(ops : Array[@lib.Operation]) -> String {
  let sb = StringBuilder()
  for op in ops {
    sb.write_string("    · 操作 ")
    sb.write_string(op.id.to_string())
    sb.write_string(": ")
    sb.write_string(@lib.op_line(op))
    sb.write_string("\n")
  }
  sb.to_string()
}

///|
fn cmd_minimize(cli : Cli) -> Int32 raise {
  // 与 cmd_check 同理：用法错误（2）优先于数据错误（4）。
  let model = match require_model(cli) {
    Some(m) => m
    None => return EXIT_USAGE
  }
  let history = load_history(cli.history_path)
  let original_n = history.length()
  // --budget-ms 之前被硬编码的 default() 吞掉：用户给 10ms 就是想让大历史
  // 快速返回，结果工具默默按 5s 跑 —— 显式参数必须生效。
  let cfg : @lib.CheckConfig = {
    time_budget_ms: cli.budget_ms,
    max_states: 200_000,
    allow_unknown_results: false,
  }
  // 用四态入口区分「线性一致 / 已判定违规且有见证 / 无合格见证 / 未下结论」。
  //
  // 旧实现用的是 `minimize_witness`（`Violation?`），而它把 `Unknown` 也编码成
  // `Some(Violation{ ops = 全部操作 })` —— 于是「预算耗尽」与「已判定违规」在
  // 这个返回值上不可区分，CLI 会把一次没跑完的搜索渲染成 `✗ NON-LINEARIZABLE`
  // + exit 1，正是 `docs/exit-codes.md` 点名要避免的最坏情形。
  match @lib.minimize_outcome(history, model, cfg) {
    @lib.Inconclusive(reason) => {
      // 与 `check` 同口径：没有结论就是 3，且不得出现 NON-LINEARIZABLE 字样。
      if cli.json {
        println(unknown_json(reason))
      } else {
        println("? UNKNOWN  \{reason}")
        println(
          "  无法最小化：检查本身没有给出结论，因此不存在可输出的见证。",
        )
        println(
          "  提示：--budget-ms 给得太小或历史过大时会出现这种情况；放开预算后重跑。",
        )
      }
      EXIT_UNKNOWN
    }
    @lib.NoWitness => {
      if cli.json {
        println(no_witness_json(original_n))
      } else {
        println("✗ NON-LINEARIZABLE")
        println("")
        println(
          "  最小化：\{original_n} 个操作里找不到可输出的最小见证（历史本身确实违规）。",
        )
        println("")
        // **按成因给方向**（LC-A4，2026-11-10 审计）：旧文案一律说
        // 「数据自相矛盾」，但 2-op stale read 这类竞态对同样走 NoWitness
        // （可解释性守卫拒收「线性一致的同伴」），与 check --json 的
        // reason=concurrency-race 自相矛盾。用同一份 check 判定分流。
        // 分流必须三态（LC-8，2026-11-17 审计）：这次再查也可能没有结论
        // （预算在两次搜索之间被耗掉 / 机器负载变化），此时既不能断言竞态、
        // 也不能断言自相矛盾。旧实现写成 `_ => "concurrency-race"`，
        // 把一个「不知道」编造成了具体成因。
        println(
          "  \{no_witness_reason_text(original_n, @lib.check(history, model, cfg))}",
        )
      }
      EXIT_VIOLATION
    }
    @lib.Consistent => {
      if cli.json {
        // 与 `check` 共用同一个构造器：同一个量（历史操作数）在整条 CLI 里
        // 只能有一个键名（LC-16）。
        println(linearizable_json(original_n))
      } else {
        println("✓ 历史线性一致，没有反例需要最小化。")
      }
      EXIT_OK
    }
    @lib.MinViolation(v) => {
      // 硬性验证：最小化产物必须仍然违规。
      //
      // 这里必须用用户给的预算，不能回落到 `CheckConfig::default()`：那不是
      // 「再验证」，而是用另一个（宽松得多）的配置替用户重跑一遍 —— 预算
      // 一旦被截断，主检查报 Unknown、再验证却跑通，结论就被偷偷升级了。
      let witness = @lib.History::{ operations: v.ops, }
      let confirmed = match @lib.check(witness, model, cfg) {
        @lib.Violation(_) => true
        @lib.Unknown(reason) => {
          if cli.json {
            println(unknown_json(reason))
          } else {
            println("? UNKNOWN  \{reason}")
            println("  \{v.explanation}")
          }
          return EXIT_UNKNOWN
        }
        _ => false
      }
      if cli.json {
        // 退出码与 JSON 结论必须一致：confirmed=false 意味着连 check 都
        // 无法复现这个「见证」，此时宣称 non-linearizable 是把脚本当猴耍
        // —— 它会把这个历史记成一个已证实的 bug。未知就写 unknown。
        let verdict = if confirmed { "non-linearizable" } else { "unknown" }
        println(json_violation(v, history, verdict))
        if !confirmed {
          println(
            "{\"note\":\"witness could not be re-confirmed by check\",\"reason\":\"witness chain broken\"}",
          )
        }
      } else {
        println(if confirmed { "✗ NON-LINEARIZABLE" } else { "? UNKNOWN" })
        println("")
        println("  最小化：\{original_n} → \{v.ops.length()} 个操作")
        println(
          "  再验证：\{if confirmed { "仍违规 ✓" } else { "未能复现 ✗" }}",
        )
        println("")
        println(render_ops_indented(v.ops))
        println("")
        println("  \{v.explanation}")
      }
      if confirmed {
        EXIT_VIOLATION
      } else {
        EXIT_UNKNOWN
      }
    }
  }
}

// ── visualize ─────────────────────────────────────────────────────────

///|
fn cmd_visualize(cli : Cli) -> Int32 raise {
  // 与 cmd_check 同理：用法错误（2）优先于数据错误（4）。
  let model = match require_model(cli) {
    Some(m) => m
    None => return EXIT_USAGE
  }
  let history = load_history(cli.history_path)
  // 与 cmd_check / cmd_minimize 同口径：显式 --budget-ms 必须生效。
  //
  // 旧实现传的是 `CheckConfig::default()`（5 秒），于是 `--budget-ms 1` 被静默
  // 忽略：同一份历史下 `check` 探索 1536 个节点就报 unknown，`visualize` 却跑完
  // 135181 个节点并断言违规（退出码 1）。用户以为限了预算，拿到的是另一次
  // 搜索的结论 —— 退出码因此与 check 矛盾。
  let cfg : @lib.CheckConfig = {
    time_budget_ms: cli.budget_ms,
    max_states: 200_000,
    allow_unknown_results: false,
  }
  match @lib.check(history, model, cfg) {
    @lib.Linearizable => {
      println(@lib.render_timeline(history))
      EXIT_OK
    }
    @lib.Violation(v) => {
      // render_violation 内部会画见证子集的时间轴；若这里再画一遍
      // 全量时间轴，同一条历史会出现两次几乎相同的图。只保留前者。
      println(@lib.render_violation(v, history))
      EXIT_VIOLATION
    }
    @lib.Unknown(reason) => {
      println(@lib.render_timeline(history))
      println("")
      println("? 结论未知：\{reason}")
      EXIT_UNKNOWN
    }
  }
}

// ── gen ───────────────────────────────────────────────────────────────

///|
/// 计数值（`--processes` / `--ops`）不得为负（LC-14，2026-11-17-b 审计）。
///
/// 库层把 `processes < 1` 钳成 1、把 `ops_per_process < 0` 钳成 0，那是给
/// **程序化调用方**的既有行为（`total_ops_checked` 与两个生成器都这么写，
/// `src/audit_round6_test.mbt` 锁着这条库级语义）。但 CLI 是用户入口，
/// 钳制在两条命令上都会把一次笔误变成一个看起来正常的产物：
///
/// ```text
/// $ lincheck gen --model register --processes 2 --ops -1 --seed 1
/// （没有任何输出）                                  exit 0   # 空历史 + 成功
/// $ lincheck gen --model register --processes -2 --ops 2 --seed 1
/// {"id":0,"process":0,...}                          exit 0   # 写了 -2，拿到 1 个客户端
/// ```
///
/// 第一条尤其危险：这份空历史随后被 `check` 消费时会得到
/// `{"verdict":"linearizable","total":0}` —— 一条流水线就此拿到「通过」的空结果，
/// 与 LC-1（`selfcheck --ops 0` 空跑 PASS）同一族。那一轮只修了 `selfcheck`
/// 这一侧，`gen` 这一侧的镜像缺口留在这里。**显式的空历史只能由 `--ops 0`
/// 表达**；`--processes 0` 仍然钳制为 1（2026-11-10 LC-A3 的显式契约，
/// `docs/DEMO.md:176-181` 写明、`cli_exit_code_test.mbt` 锁着 exit 0）。
///
/// 返回 `false` 时原因已经打到 stderr，调用方只需 exit 2。
///
/// `--seeds`（LC-19）是同一个守卫轴的第三个参数：`cmd_selfcheck` 把
/// `seeds < 1` 钳成 1 轮，于是 `--seeds -3` 静默跑 1 轮并 PASS。危害比
/// `--ops -1` 小（真的做了工作，头部也如实报 `seeds=1`），但归类相同 ——
/// 负数不是计数。`--seeds 0` 保持钳制：1 轮是实打实的工作，与 `--ops 0`
/// 的「一条历史都没生成」不是一回事。
fn count_args_non_negative(cli : Cli) -> Bool {
  if cli.ops_per_process < 0 {
    eprintln(
      "用法错误: --ops \{cli.ops_per_process} 不能为负——负数不是操作数，钳成 0 等于静默给出一份空历史；要空历史请写 --ops 0",
    )
    return false
  }
  if cli.processes < 0 {
    eprintln(
      "用法错误: --processes \{cli.processes} 不能为负——客户端数是非负计数，钳成 1 等于替用户改写意图；--processes 0 按既有契约钳制为 1",
    )
    return false
  }
  if cli.seeds < 0 {
    eprintln(
      "用法错误: --seeds \{cli.seeds} 不能为负——种子轮数是非负计数，钳成 1 等于替用户改写工作量；--seeds 0 按既有契约跑 1 轮",
    )
    return false
  }
  true
}

///|
/// `--concurrency` 的域是 `[0, 1]`（`API.md` §5：0 = 全串行，1 = 完全随机并发）。
///
/// 库层 `generate_consistent` / `generate_random` 对越界值做钳制，那是给
/// **程序化调用方**的既有行为，保留不动。但 CLI 是用户入口：把 `2.5` 悄悄换成
/// `1.0`、把 `-0.5` 换成 `0`，等于替用户改写意图，而用户拿到的历史与他写的
/// 参数毫无关系——与 `--ops` / `--processes` 越界同口径，必须 exit 2。
///
/// 注意「域外」与「小数」是两件事：并发度是期望值不是计数，`0.5` 照旧合法。
fn concurrency_in_domain(value : Double) -> Bool {
  value >= 0.0 && value <= 1.0
}

///|
fn cmd_gen(cli : Cli) -> Int32 {
  let model = match require_model(cli) {
    Some(m) => m
    None => return EXIT_USAGE
  }
  // 计数符号先于取值域：`--ops -1` 与 `--concurrency 2.5` 是两类错误，
  // 前者连「规模」都不是（LC-14），后者是域外值（LC-5）。
  if !count_args_non_negative(cli) {
    return EXIT_USAGE
  }
  if !concurrency_in_domain(cli.concurrency) {
    eprintln(
      "用法错误: --concurrency \{cli.concurrency} 超出取值范围 [0, 1]（0 = 全串行，1 = 完全随机并发）",
    )
    return EXIT_USAGE
  }
  // 规模参数先校验：`processes × ops_per_process` 是用户可控的 Int32 乘积，
  // 溢出会让生成器回绕出一个毫不相关的循环上界（最坏的一档回绕成 0，
  // 静默产出一份空历史并 exit 0）。用法错误（2）优先于「生成成功」——
  // 与 parse_int_arg 对单值溢出的口径一致。
  match @lib.total_ops_checked(cli.processes, cli.ops_per_process) {
    Some(_) => ()
    None => {
      // 两条拒绝理由分开说（LC-A1，2026-11-10 审计）：Int32 回绕与
      // 「超出可行规模」是不同的用户动作——前者要换算参数，后者要么
      // 缩小规模、要么分批跑。混成一句会把「2147483647 × 1」这种
      // 并不自相矛盾的输入说成「超出 Int32 范围」（它并没有）。
      let procs = if cli.processes < 1 { 1 } else { cli.processes }
      let per_proc = if cli.ops_per_process < 0 {
        0
      } else {
        cli.ops_per_process
      }
      let overflowed = per_proc != 0 && procs > 2147483647 / per_proc
      if overflowed {
        eprintln(
          "用法错误: --processes \{cli.processes} × --ops \{cli.ops_per_process} 超出 Int32 范围，无法生成历史（每客户端 --ops 条，总数 = processes × ops）",
        )
      } else {
        eprintln(
          "用法错误: --processes \{cli.processes} × --ops \{cli.ops_per_process} = \{procs * per_proc} 条操作，超出单次 gen 的可行上限 \{@lib.MAX_GENERATED_OPS}（生成器按总数分配数组，再多会挂死而不是报错；请缩小规模或分批生成）",
        )
      }
      return EXIT_USAGE
    }
  }
  let cfg = @lib.GenConfig::{
    processes: cli.processes,
    ops_per_process: cli.ops_per_process,
    seed: cli.seed,
    concurrency: cli.concurrency,
  }
  let history = match cli.mode {
    "random" => @lib.generate_random(model, cfg)
    "inject" =>
      @lib.inject_violation(
        @lib.generate_consistent(model, cfg),
        model,
        cli.seed,
      )
    _ => @lib.generate_consistent(model, cfg)
  }
  println(history.to_jsonl())
  EXIT_OK
}

// ── selfcheck ─────────────────────────────────────────────────────────

///|
/// `selfcheck` 的规模必须「可生成**且**非空」。
///
/// `total_ops_checked` 的公开语义保持不变（`Some(0)` 是合法输入：`gen --ops 0`
/// 的契约就是产出空历史，见 `docs/DEMO.md`）。但 `selfcheck` 是元测试，
/// 0 条操作意味着**一条历史都没生成、一次检查都没做**，此时打印
/// 「合法历史全部通过」是虚假结论——`API.md` §7 明文禁止把生成器兜底的空历史
/// 当成一次通过的 selfcheck。
///
/// 0 有两个来源，都必须拒绝：`--ops 0`；以及 `--ops` 为负（`total_ops_checked`
/// 按既有规则把负值钳成 0）。
fn selfcheck_scale(cli : Cli) -> Int32? {
  match @lib.total_ops_checked(cli.processes, cli.ops_per_process) {
    Some(total) =>
      if total >= 1 {
        Some(total)
      } else {
        eprintln(
          "用法错误: selfcheck 的 --processes \{cli.processes} × --ops \{cli.ops_per_process} 生成 0 个操作——一条历史都没生成，元测试无法验证任何东西；--ops 必须 ≥ 1（0 与负值都会生成空历史）",
        )
        None
      }
    None => {
      eprintln(
        "用法错误: selfcheck 的 --processes \{cli.processes} × --ops \{cli.ops_per_process} 超出可用范围（乘积不得溢出 Int32，且总数不得超过 \{@lib.MAX_GENERATED_OPS}）",
      )
      None
    }
  }
}

///|
/// `selfcheck` 摘要的**头部**：三个规模量各就各位。
///
/// 抽成纯函数是为了让它可断言（main 包的 `*_test.mbt` 拿不到 stdout，但
/// `*_wbtest.mbt` 能直接调私有函数）。`processes` 传**命令行上写的**值，
/// 钳制在这里做一次（`--processes 0` → 1，与生成器同口径），`ops_per_seed`
/// 传已经过 `selfcheck_scale` 校验的乘积，避免第二处重算。
fn selfcheck_header(
  model : String,
  seeds : Int32,
  processes : Int32,
  ops_per_process : Int32,
  ops_per_seed : Int32,
) -> String {
  let clients = if processes < 1 { 1 } else { processes }
  "selfcheck  model=\{model}  seeds=\{seeds}  clients=\{clients}  ops/client=\{ops_per_process}  ops/seed=\{ops_per_seed}"
}

///|
/// `selfcheck` 摘要的**计数段**：五个计数全部是「seed 的个数」，口径必须写清。
///
/// - `failed` **从这里派生**（`violations + unknowns`），不再单独累加：
///   两份计数各加一次迟早会分叉，而 PASS 判据读的正是 `failed`；
/// - 「注入违规被发现：a / b」的 b 是**真的做过注入的 seed 数**（不是 `seeds`），
///   两者在 n ≥ 1 时相等（`src/audit_inject_invariant_test.mbt`），但语义不同，
///   所以分母用 `injected`；
/// - `injected < seeds` 时补一行诊断：那时 PASS 会变成无证据通过，必须说出原因。
fn selfcheck_body(
  violations : Int32,
  unknowns : Int32,
  injected : Int32,
  injected_missed : Int32,
  seeds : Int32,
) -> String {
  let failed = violations + unknowns
  let lines : Array[String] = []
  lines.push(
    "  · 合法历史全部通过：\{if failed == 0 { "是 ✓" } else { "否 ✗" }}",
  )
  lines.push("    - 误判违规：\{violations}")
  lines.push("    - 结论未知：\{unknowns}")
  lines.push(
    "  · 注入违规被发现：\{injected - injected_missed} / \{injected}",
  )
  if injected < seeds {
    // 防御性诊断（当前不可达，见 src/audit_inject_invariant_test.mbt 的可证明性）：
    // 一旦注入模板改坏到「合法历史改不动」，PASS 会变成无证据通过，
    // 这行必须把原因说出来，而不是只留一个 0 / 0。
    lines.push(
      "    - 未产生注入的 seed：\{seeds - injected}（注入模板为空，或本配置下所有单点改写都能被模型吸收）",
    )
  }
  lines.join("\n")
}

///|
fn cmd_selfcheck(cli : Cli) -> Int32 {
  let model = match require_model(cli) {
    Some(m) => m
    None => return EXIT_USAGE
  }
  // 负计数与 `gen` 同口径先拒（LC-14）：`selfcheck --processes -1` 曾在
  // 钳制后「正常」跑完并打出 PASS，而用户写的客户端数根本不存在。
  if !count_args_non_negative(cli) {
    return EXIT_USAGE
  }
  // 与 gen 共用同一份规模校验，并额外要求「至少一个操作」。
  // 库层生成器对不可用规模（含 0 条）的兜底是空历史；CLI 若不在此拒绝，
  // 会把「一个操作都没生成」渲染成 PASS + exit 0。
  let ops_per_seed = match selfcheck_scale(cli) {
    Some(n) => n
    None => return EXIT_USAGE
  }
  let total = if cli.seeds < 1 { 1 } else { cli.seeds }
  let mut seed = 1
  let mut violations = 0
  let mut unknowns = 0
  let mut injected = 0
  let mut injected_missed = 0
  while seed <= total {
    // 并发度在 0..1 之间轮转，覆盖串行到完全并发
    let conc = (seed % 11).to_double() / 10.0
    let cfg = @lib.GenConfig::{
      processes: cli.processes,
      ops_per_process: cli.ops_per_process,
      seed,
      concurrency: conc,
    }
    let h = @lib.generate_consistent(model, cfg)
    // `failed` 不再单独累加：它就是 `violations + unknowns`（见 selfcheck_body）。
    match @lib.check(h, model, @lib.CheckConfig::default()) {
      @lib.Linearizable => ()
      @lib.Violation(_) => violations = violations + 1
      @lib.Unknown(_) => unknowns = unknowns + 1
    }
    // 顺手做注入测试：制造违规，检查器必须发现
    let bad = @lib.inject_violation(h, model, seed)
    if bad.to_jsonl() != h.to_jsonl() {
      injected = injected + 1
      match @lib.check(bad, model, @lib.CheckConfig::default()) {
        @lib.Violation(_) => ()
        _ => injected_missed = injected_missed + 1
      }
    }
    seed = seed + 1
  }
  println(
    selfcheck_header(
      cli.model,
      total,
      cli.processes,
      cli.ops_per_process,
      ops_per_seed,
    ),
  )
  println(
    selfcheck_body(violations, unknowns, injected, injected_missed, total),
  )
  // PASS 的判据必须**同时**覆盖两件事：合法历史不被误判，且每一档都真的做过
  // 一次注入检出。旧判据只看 failed 与 injected_missed，于是「一条都没注入」
  // 也算通过 —— 那正是「注入违规被发现：0 / 0 → PASS」的来源。
  //
  // `failed` 不再是一个独立累加器，判据直接读两个来源计数：
  // `violations + unknowns == 0`（显示那一行由 selfcheck_body 派生）。
  if violations == 0 &&
    unknowns == 0 &&
    injected_missed == 0 &&
    injected == total {
    println("结果：PASS")
    EXIT_OK
  } else {
    println("结果：FAIL")
    EXIT_VIOLATION
  }
}

// ── 入口 ──────────────────────────────────────────────────────────────

///|
/// 全部已知参数名（顺序即用法里的分组）。解析器只认这些。
fn all_flags() -> Array[String] {
  [
    "--history", "--model", "--budget-ms", "--json", "--seeds", "--processes", "--ops",
    "--seed", "--concurrency", "--consistent", "--random", "--inject",
  ]
}

///|
/// 某个子命令**接受**的参数白名单。
///
/// 为什么必须逐个子命令精确化（2026-11-17 审计 LC-4）：旧解析器五个子命令共用
/// 一套 flag，别的子命令的参数被收下后静默丢弃 —— 例如
/// `selfcheck --budget-ms 1` 收下参数、`cmd_selfcheck` 却用
/// `CheckConfig::default()`，预算完全不生效，输出与不带该参数逐字节相同。
/// 用户以为限了预算。只能打印不能生效的守卫比没有守卫更糟。
fn flags_for(cmd : String) -> Array[String] {
  if cmd == "check" || cmd == "minimize" {
    ["--history", "--model", "--budget-ms", "--json"]
  } else if cmd == "visualize" {
    // visualize 没有 --json：它的输出是人读的时间轴，没有机器格式。
    ["--history", "--model", "--budget-ms"]
  } else if cmd == "gen" {
    // gen 的输出本来就是 JSONL，也只按 seed/规模/模式生成历史。
    [
      "--model", "--processes", "--ops", "--seed", "--concurrency", "--consistent",
      "--random", "--inject",
    ]
  } else {
    // selfcheck：生成 + 逐 seed 检查，不接受时间预算（内部用默认档）。
    ["--model", "--processes", "--ops", "--seeds"]
  }
}

///|
/// 某个参数属于哪些子命令（报错文案用）。
fn flag_owners(flag : String) -> String {
  if flag == "--history" {
    "check / minimize / visualize"
  } else if flag == "--budget-ms" {
    "check / minimize / visualize"
  } else if flag == "--json" {
    "check / minimize"
  } else if flag == "--seeds" {
    "selfcheck"
  } else if flag == "--processes" || flag == "--ops" {
    "gen / selfcheck"
  } else if flag == "--seed" || flag == "--concurrency" {
    "gen"
  } else if flag == "--consistent" || flag == "--random" || flag == "--inject" {
    "gen"
  } else {
    "所有子命令"
  }
}

///|
/// 白名单校验：命令行上出现过的每个参数都必须属于当前子命令。
///
/// 返回 `false` 时原因已经打到 stderr，调用方只需 exit 2。
/// 这一层只判「这个参数归不归这个子命令」；值域与规模（`--concurrency`
/// 的 `[0, 1]`、`processes × ops` 的溢出与上限、`selfcheck` 至少一个操作）
/// 由各子命令紧接着自己判 —— 那些判据依赖具体命令的语义，硬塞进白名单会让
/// 一个函数同时管两件事。
fn validate_flags(cmd : String, cli : Cli) -> Bool {
  let allowed = flags_for(cmd)
  for flag in cli.used {
    let mut ok = false
    for a in allowed {
      if a == flag {
        ok = true
      }
    }
    if !ok {
      eprintln(
        "用法错误: \{flag} 不适用于子命令 \{cmd}（它属于 \{flag_owners(flag)}）",
      )
      return false
    }
  }
  true
}

///|
/// 解析命令行：逐项消费 argv，遇到无法识别的形态返回 None。
///
/// 用递归传递不可变 Cli 值（MoonBit 记录字段默认不可变，需要 mut 才能原地改）。
fn parse_from(cli : Cli, argv : Array[String], i : Int32) -> Cli? {
  if i >= argv.length() {
    return Some(cli)
  }
  let flag = argv[i]
  // 先判「这个参数名认不认识」，认不出就走原有的参数错误路径；认识就记下来，
  // 交给 validate_flags 按子命令核对（LC-4）。
  let mut known = false
  for k in all_flags() {
    if k == flag {
      known = true
    }
  }
  if !known {
    return None
  }
  cli.used.push(flag)
  if flag == "--json" {
    parse_from({ ..cli, json: true, }, argv, i + 1)
  } else if flag == "--consistent" {
    parse_from({ ..cli, mode: "consistent", }, argv, i + 1)
  } else if flag == "--random" {
    parse_from({ ..cli, mode: "random", }, argv, i + 1)
  } else if flag == "--inject" {
    parse_from({ ..cli, mode: "inject", }, argv, i + 1)
  } else if i + 1 >= argv.length() || all_flags().contains(argv[i + 1]) {
    // 已知选项出现在值的位置时，当前带值参数就是缺值；不能把这个选项
    // 吞成路径/模型名，更不能把随后的文件读取失败误报成数据错误。
    // 负数仍以单个 '-' 开头，不受影响；以 '--' 开头的真实路径可写成 './--name'。
    None
  } else {
    let value = argv[i + 1]
    if flag == "--history" {
      parse_from({ ..cli, history_path: value, }, argv, i + 2)
    } else if flag == "--model" {
      parse_from({ ..cli, model: value, }, argv, i + 2)
    } else if flag == "--budget-ms" {
      match parse_int_arg(value) {
        Some(v) => parse_from({ ..cli, budget_ms: v, }, argv, i + 2)
        None => None
      }
    } else if flag == "--seeds" {
      match parse_int_arg(value) {
        Some(v) => parse_from({ ..cli, seeds: v, }, argv, i + 2)
        None => None
      }
    } else if flag == "--processes" {
      match parse_int_arg(value) {
        Some(v) => parse_from({ ..cli, processes: v, }, argv, i + 2)
        None => None
      }
    } else if flag == "--ops" {
      match parse_int_arg(value) {
        Some(v) => parse_from({ ..cli, ops_per_process: v, }, argv, i + 2)
        None => None
      }
    } else if flag == "--seed" {
      match parse_int_arg(value) {
        Some(v) => parse_from({ ..cli, seed: v, }, argv, i + 2)
        None => None
      }
    } else if flag == "--concurrency" {
      match parse_double_arg(value) {
        Some(v) => parse_from({ ..cli, concurrency: v, }, argv, i + 2)
        None => None
      }
    } else {
      None
    }
  }
}

///|
/// 解析命令行；出错返回 None
fn parse_args(cmd : String, argv : Array[String]) -> Cli? {
  parse_from(default_cli(cmd), argv, 2)
}

///|
/// 执行一次调用并返回退出码。
///
/// 标 `pub` 仅为可测性，理由同 `parse_int_arg`：可执行包没有下游消费者，而
/// 主包的 `*_test.mbt` 只能看到 pub 符号。退出码是 `docs/exit-codes.md` 的核心
/// 契约（`1` = 有效结论 / `3` = 没有结论），只有直接断言它才能锁住
/// 「预算耗尽不得被渲染成已判定违规」这类缺陷。
pub fn run(argv : Array[String]) -> Int32 {
  if argv.length() < 2 {
    usage()
    return EXIT_USAGE
  }
  let cmd = argv[1]
  if cmd == "help" || cmd == "--help" || cmd == "-h" {
    usage()
    return EXIT_OK
  }
  let known = ["check", "minimize", "visualize", "gen", "selfcheck"]
  let mut valid = false
  for k in known {
    if k == cmd {
      valid = true
    }
  }
  if !valid {
    println("未知子命令：\{cmd}")
    println("")
    usage()
    return EXIT_USAGE
  }
  match parse_args(cmd, argv) {
    None => {
      println("参数错误（缺值或数值非法）")
      println("")
      usage()
      EXIT_USAGE
    }
    Some(c) => {
      // 参数白名单先于一切（LC-4）：别的子命令的参数不许静默丢弃。
      // 用法错误（2）优先于数据错误（4）与「生成成功」——与既有口径一致。
      if !validate_flags(c.command, c) {
        return EXIT_USAGE
      }
      let result : Int32 = try {
        match c.command {
          "check" => cmd_check(c)
          "minimize" => cmd_minimize(c)
          "visualize" => cmd_visualize(c)
          "gen" => cmd_gen(c)
          _ => cmd_selfcheck(c)
        }
      } catch {
        Failure(msg) => {
          println("用法错误：\{msg}")
          EXIT_USAGE
        }
        DataFailure(msg) => {
          println("数据错误：\{msg}")
          EXIT_DATA
        }
        _ => {
          println("内部错误")
          EXIT_UNKNOWN
        }
      }
      result
    }
  }
}

///|
fn main {
  let argv = @env.args()
  let code = run(argv)
  @sys.exit(code)
}
