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
/// 解析 "0.5" / "1" 这类简单浮点。
///
/// 符号必须对整个数值生效：小数部分只按无符号数解析，最后统一乘上
/// 整体符号。直接把负号塞给整数段会让 `-0.5` 变成 `+0.5`（整数段是
/// 0，负号被静默丢掉），`-1.5` 变成 `-0.5`。
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
    match parse_int_arg(body) {
      Some(v) => if neg { Some(-v.to_double()) } else { Some(v.to_double()) }
      None => None
    }
  } else if parts.length() == 2 {
    let whole = match parse_int_arg(parts[0].to_owned()) {
      Some(v) => v
      None => return None
    }
    let frac_s = parts[1].to_owned()
    if frac_s.length() == 0 {
      return None
    }
    let frac = match parse_int_arg(frac_s) {
      Some(v) => v
      None => return None
    }
    let mut scale = 1.0
    let mut i = 0
    while i < frac_s.length() {
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
fn load_history(path : String) -> @lib.History raise {
  if path.length() == 0 {
    raise Failure("缺少 --history")
  }
  let text : String = @fs.read_file_to_string(path) catch {
    _ => raise DataFailure("读不到文件：\{path}")
  }
  match @lib.History::from_jsonl(text) {
    Ok(h) => h
    Err(_) => raise DataFailure("JSONL 解析失败：\{path}")
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
        println("{\"verdict\":\"linearizable\",\"ops\":\{history.length()}}")
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
        println("{\"verdict\":\"unknown\",\"reason\":\"\{reason}\"}")
      } else {
        println("? UNKNOWN  \{reason}")
      }
      EXIT_UNKNOWN
    }
  }
}

// ── minimize ──────────────────────────────────────────────────────────

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
  // 用可空入口明确区分「最小化：N → M」与「找不到可输出的见证」。
  // 后者退出码仍是 1：历史确实违规是一个有效结论，只是没有满足
  // 「下界 + 可解释性」的证据子集可给——不能静默把退化解（1 条操作）
  // 当作最小反例输出，也不能降级成 0/3。
  let v = match @lib.minimize_witness(history, model, cfg) {
    Some(w) => w
    None => {
      if cli.json {
        println(
          "{\"verdict\":\"non-linearizable\",\"total\":\{original_n},\"witness\":[],\"reason\":\"no-explainable-witness\"}",
        )
      } else {
        println("✗ NON-LINEARIZABLE")
        println("")
        println(
          "  最小化：\{original_n} 个操作里找不到可输出的最小见证（历史本身确实违规）。",
        )
        println("")
        println(
          "  \{@lib.no_explainable_witness_text(original_n, @lib.MIN_WITNESS)}",
        )
      }
      return EXIT_VIOLATION
    }
  }
  if v.ops.length() == 0 {
    if cli.json {
      println("{\"verdict\":\"linearizable\",\"total\":\{original_n}}")
    } else {
      println("✓ 历史线性一致，没有反例需要最小化。")
    }
    EXIT_OK
  } else {
    // 硬性验证：最小化产物必须仍然违规
    let witness = @lib.History::{ operations: v.ops, }
    let confirmed = match
      @lib.check(witness, model, @lib.CheckConfig::default()) {
      @lib.Violation(_) => true
      @lib.Unknown(reason) => {
        if cli.json {
          println("{\"verdict\":\"unknown\",\"reason\":\"\{reason}\"}")
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

// ── visualize ─────────────────────────────────────────────────────────

///|
fn cmd_visualize(cli : Cli) -> Int32 raise {
  // 与 cmd_check 同理：用法错误（2）优先于数据错误（4）。
  let model = match require_model(cli) {
    Some(m) => m
    None => return EXIT_USAGE
  }
  let history = load_history(cli.history_path)
  match @lib.check(history, model, @lib.CheckConfig::default()) {
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
fn cmd_gen(cli : Cli) -> Int32 {
  let cfg = @lib.GenConfig::{
    processes: cli.processes,
    ops_per_process: cli.ops_per_process,
    seed: cli.seed,
    concurrency: cli.concurrency,
  }
  let model = match require_model(cli) {
    Some(m) => m
    None => return EXIT_USAGE
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
fn cmd_selfcheck(cli : Cli) -> Int32 {
  let model = match require_model(cli) {
    Some(m) => m
    None => return EXIT_USAGE
  }
  let total = if cli.seeds < 1 { 1 } else { cli.seeds }
  let mut seed = 1
  let mut failed = 0
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
    match @lib.check(h, model, @lib.CheckConfig::default()) {
      @lib.Linearizable => ()
      @lib.Violation(_) => {
        violations = violations + 1
        failed = failed + 1
      }
      @lib.Unknown(_) => {
        unknowns = unknowns + 1
        failed = failed + 1
      }
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
    "selfcheck  model=\{cli.model}  seeds=\{total}  ops/seed=\{cli.ops_per_process}",
  )
  println(
    "  · 合法历史全部通过：\{if failed == 0 { "是 ✓" } else { "否 ✗" }}",
  )
  println("    - 误判违规：\{violations}")
  println("    - 结论未知：\{unknowns}")
  println(
    "  · 注入违规被发现：\{injected - injected_missed} / \{injected}",
  )
  if failed == 0 && injected_missed == 0 {
    println("结果：PASS")
    EXIT_OK
  } else {
    println("结果：FAIL")
    EXIT_VIOLATION
  }
}

// ── 入口 ──────────────────────────────────────────────────────────────

///|
/// 解析命令行：逐项消费 argv，遇到无法识别的形态返回 None。
///
/// 用递归传递不可变 Cli 值（MoonBit 记录字段默认不可变，需要 mut 才能原地改）。
fn parse_from(cli : Cli, argv : Array[String], i : Int32) -> Cli? {
  if i >= argv.length() {
    return Some(cli)
  }
  let flag = argv[i]
  if flag == "--json" {
    parse_from({ ..cli, json: true, }, argv, i + 1)
  } else if flag == "--consistent" {
    parse_from({ ..cli, mode: "consistent", }, argv, i + 1)
  } else if flag == "--random" {
    parse_from({ ..cli, mode: "random", }, argv, i + 1)
  } else if flag == "--inject" {
    parse_from({ ..cli, mode: "inject", }, argv, i + 1)
  } else if i + 1 >= argv.length() {
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
fn run(argv : Array[String]) -> Int32 {
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
