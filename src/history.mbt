/// # 历史模型（history.mbt）
///
/// 一次并发执行被记录成一组**操作**。每个操作带有两个逻辑时间戳：
///
/// ```text
///             start                end
///               |                   |
///   process 0   [====== Write(1) ======]
/// ```
///
/// `start` 是调用发生的时刻，`end` 是响应返回的时刻。所有进程共用同一台逻辑时钟，
/// 因此两个操作的时间区间关系直接决定它们是否可能并发：
///
/// - `a.end < b.start` → a 在 b 之前结束，**必须**先于 b 生效（happens-before）
/// - 区间重叠（互相都不满足上面的条件）→ 二者**并发**，可以任意排序
///
/// 这两条关系就是线性一致性检查的全部输入：检查器要判断是否存在一个全序，
/// 既尊重所有 happens-before，又让每个操作返回它声明的结果。

///|
/// 操作标识符。检查器内部只用它做排序与报告，不要求连续。
pub type OpId = Int32

///|
/// 操作种类。
///
/// 注意：`Cas` 的字段在契约文档里写作 `Cas(expected : Int, new : Int)`，
/// MoonBit 的枚举变体不接受这种带标签的写法（会报 `Expected upper case identifier`），
/// 因此这里使用等价的**位置参数** `Cas(Int, Int)`，语义顺序仍是 `(期望值, 新值)`。
pub(all) enum OpKind {
  Write(Int32) // 写入值
  Read // 读取
  Cas(Int32, Int32) // 比较并交换：(expected, new)
  Append(Int32) // 队列/日志追加
  Pop // 队列弹出
} derive(Eq, Debug)

///|
/// 操作返回的结果。
///
/// `Nil` 表示"结果未知/超时"——检查器默认把它当作**任何值都不匹配**，
/// 只有在 `CheckConfig.allow_unknown_results = true` 时才允许它匹配任意期望值。
pub(all) enum OpResult {
  Ok // 写成功
  Value(Int32) // 读到的值
  Bool(Bool) // CAS / Pop 成功与否
  Empty // Pop 时队列为空
  Nil // 超时/未知
} derive(Eq, Debug)

///|
/// 一条历史记录中的单个操作。
pub(all) struct Operation {
  id : OpId
  process : Int32
  kind : OpKind
  result : OpResult
  start : Int64 // 逻辑时间戳（调用发生）
  end : Int64 // 逻辑时间戳（响应发生）
} derive(Eq, Debug)

///|
/// 一段待检查的历史：若干操作的集合。
pub(all) struct History {
  operations : Array[Operation]
}

///|
/// 新建空历史。
pub fn History::new() -> History {
  { operations: [], }
}

///|
/// 追加一个操作（就地修改 `operations`，Array 是引用语义）。
pub fn History::add(self : History, op : Operation) -> Unit {
  self.operations.push(op)
}

///|
/// 操作数量。
pub fn History::length(self : History) -> Int32 {
  self.operations.length()
}

///|
/// 操作的全序比较：先 `start`，再 `id`（两个键都是升序）。
///
/// **不要用减法实现**（`a.start - b.start` / `a.id - b.id`）：`start` 是完整
/// Int64、`id` 是完整 Int32（audit2_test 锁定边界值），两端差值会溢出，
/// 比较结果不再传递，`sort_by` 得到的顺序会与实际大小关系相反。
/// 这是可复现的契约违反：极端 id 下见证子集不再满足「按 id 升序」（见
/// `history_test.mbt` / `checker_test.mbt` 的极值回归测试）。
pub fn compare_ops(a : Operation, b : Operation) -> Int32 {
  if a.start < b.start {
    -1
  } else if a.start > b.start {
    1
  } else if a.id < b.id {
    -1
  } else if a.id > b.id {
    1
  } else {
    0
  }
}

///|
/// 只按 `id` 升序比较（见证输出排序用），同样避免减法溢出。
pub fn compare_ops_by_id(a : Operation, b : Operation) -> Int32 {
  if a.id < b.id {
    -1
  } else if a.id > b.id {
    1
  } else {
    0
  }
}

///|
/// 按 `start` 升序返回一份新历史；`start` 相同时按 `id` 升序，保证确定性。
///
/// 不改动 `self`：内部先 `copy()` 再排序。
pub fn History::sort_by_start(self : History) -> History {
  let sorted = self.operations.copy()
  sorted.sort_by(compare_ops)
  { operations: sorted, }
}

///|
/// `a` 在 `b` 开始之前就已经完成——二者不可能并发，全序中 a 必须排在 b 之前。
///
/// 严格不等号很重要：`a.end == b.start` 视为**并发**（响应与调用可能同时刻，
/// 无法确定先后），这是线性一致性定义里的标准处理方式。
pub fn happens_before(a : Operation, b : Operation) -> Bool {
  a.end < b.start
}

///|
/// 两个操作是否并发：时间区间重叠。
///
/// 即"a 不在 b 之前完成"且"b 不在 a 之前完成"。
pub fn concurrent(a : Operation, b : Operation) -> Bool {
  !(a.end < b.start) && !(b.end < a.start)
}

// ============================================================
// 人类可读的格式化（供解释文本 / 可视化共用）
// ============================================================

///|
/// 把操作种类格式化成 `Write(1)` / `Read` / `Cas(ex=1, new=2)` 这样的文本。
pub fn format_op_kind(kind : OpKind) -> String {
  match kind {
    Write(v) => "Write(" + v.to_string() + ")"
    Read => "Read"
    Cas(e, n) => "Cas(ex=" + e.to_string() + ", new=" + n.to_string() + ")"
    Append(v) => "Append(" + v.to_string() + ")"
    Pop => "Pop"
  }
}

///|
/// 把操作结果格式化成 `Ok` / `-> 2` / `-> true` / `-> Empty` 这样的文本。
pub fn format_op_result(result : OpResult) -> String {
  match result {
    Ok => "Ok"
    Value(v) => "-> " + v.to_string()
    Bool(b) => if b { "-> true" } else { "-> false" }
    Empty => "-> Empty"
    Nil => "-> Nil"
  }
}

///|
/// 单行描述一个操作：`操作 3 @proc 1: Write(1) Ok [10..20]`。
pub fn format_op(op : Operation) -> String {
  "操作 " +
  op.id.to_string() +
  " @proc " +
  op.process.to_string() +
  ": " +
  format_op_kind(op.kind) +
  " " +
  format_op_result(op.result) +
  " [" +
  op.start.to_string() +
  ".." +
  op.end.to_string() +
  "]"
}

// ============================================================
// JSONL 序列化
// ============================================================

///|
/// 单个操作 → 一行 JSON（字段顺序固定，便于 diff 与测试）：
///
/// ```json
/// {"id":0,"process":0,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":0,"end":10}
/// ```
fn operation_to_json(op : Operation) -> String {
  "{\"id\":" +
  op.id.to_string() +
  ",\"process\":" +
  op.process.to_string() +
  ",\"kind\":" +
  kind_to_json(op.kind) +
  ",\"result\":" +
  result_to_json(op.result) +
  ",\"start\":" +
  op.start.to_string() +
  ",\"end\":" +
  op.end.to_string() +
  "}"
}

///|
/// 操作种类 → 带 tag 的 JSON 对象。
fn kind_to_json(kind : OpKind) -> String {
  match kind {
    Write(v) => "{\"tag\":\"Write\",\"value\":" + v.to_string() + "}"
    Read => "{\"tag\":\"Read\"}"
    Cas(e, n) =>
      "{\"tag\":\"Cas\",\"expected\":" +
      e.to_string() +
      ",\"new\":" +
      n.to_string() +
      "}"
    Append(v) => "{\"tag\":\"Append\",\"value\":" + v.to_string() + "}"
    Pop => "{\"tag\":\"Pop\"}"
  }
}

///|
/// 操作结果 → 带 tag 的 JSON 对象。
fn result_to_json(result : OpResult) -> String {
  match result {
    Ok => "{\"tag\":\"Ok\"}"
    Value(v) => "{\"tag\":\"Value\",\"value\":" + v.to_string() + "}"
    Bool(b) =>
      if b {
        "{\"tag\":\"Bool\",\"value\":true}"
      } else {
        "{\"tag\":\"Bool\",\"value\":false}"
      }
    Empty => "{\"tag\":\"Empty\"}"
    Nil => "{\"tag\":\"Nil\"}"
  }
}

///|
/// 整段历史 → JSONL 文本（每行一个操作，末尾带换行）。
pub fn History::to_jsonl(self : History) -> String {
  let sb = StringBuilder()
  for op in self.operations {
    sb.write_string(operation_to_json(op))
    sb.write_string("\n")
  }
  sb.to_string()
}

// ============================================================
// JSONL 解析
// ============================================================

///|
/// 解析阶段的错误：非法行。
///
/// 契约写作 `BadLine(line_no : Int, reason : String)`，同样因为枚举/错误变体
/// 不支持带标签字段，这里使用等价的位置参数。
pub(all) suberror HistoryError {
  BadLine(Int32, String)
} derive(Debug)

///|
/// 从 JSON 对象里取一个整数，缺失或类型不符返回 None。
///
/// 数值必须是「数学上的整数」且落在 Int32 范围内，否则同样返回 None：
/// - `1.5` 这类小数曾直接被 `to_int()` 截成 1；
/// - 超范围的字面量曾被静默回绕（`4294967297` → 1）。
/// 两种情形都让该行变 BadLine——契约要求非法行报错，不做有损转换。
fn json_int(m : Map[String, Json], key : String) -> Int32? {
  match json_int64(m, key) {
    Some(i) => {
      if i < -2147483648L || i > 2147483647L {
        return None
      }
      Some(i.to_int())
    }
    _ => None
  }
}

///|
/// 从 JSON 对象里取一个 64 位整数（时间戳用）。
///
/// 从数字原文解析，不经 Double 舍入；小数和指数形式仅在精确值为整数时接受。
fn json_int64(m : Map[String, Json], key : String) -> Int64? {
  match m.get(key) {
    Some(Number(v, repr~)) => {
      match repr {
        Some(text) => return exact_json_integer(text)
        None => ()
      }
      // A programmatically constructed Number may lack source text. Only the
      // conventional safe-integer range can then be accepted without guessing.
      if v.is_nan() || v != v.trunc() {
        return None
      }
      if v < -9007199254740991.0 || v > 9007199254740991.0 {
        return None
      }
      Some(v.to_int64())
    }
    _ => None
  }
}

///|
/// Normalize a valid JSON number into an integer without allocating exponent
/// padding or first accumulating an overflowing mantissa. Decimal trailing zeros
/// cancel negative exponents. Negative accumulation supports Int64::MIN exactly.
fn exact_json_integer(text : StringView) -> Int64? {
  let n = text.length()
  if n == 0 {
    return None
  }
  let negative = text[0] == '-'
  let mut i = if negative { 1 } else { 0 }
  let digits : Array[Int32] = []
  let mut fractional = 0
  let mut after_dot = false
  while i < n && text[i] != 'e' && text[i] != 'E' {
    let c = text[i]
    if c == '.' {
      after_dot = true
    } else if c >= '0' && c <= '9' {
      digits.push(c.to_int() - 48)
      if after_dot {
        fractional = fractional + 1
      }
    } else {
      return None
    }
    i = i + 1
  }
  if digits.length() == 0 {
    return None
  }
  let mut exponent = 0L
  if i < n {
    i = i + 1
    let mut exponent_negative = false
    if i < n && (text[i] == '-' || text[i] == '+') {
      exponent_negative = text[i] == '-'
      i = i + 1
    }
    // Beyond this bound the exponent cannot cancel the finite mantissa length
    // or produce an in-range nonzero Int64. Saturation avoids exponent overflow.
    let exponent_cap = n.to_int64() + 20L
    if i == n {
      return None
    }
    while i < n {
      let c = text[i]
      if c < '0' || c > '9' {
        return None
      }
      if exponent < exponent_cap {
        exponent = exponent * 10L + (c.to_int() - 48).to_int64()
        if exponent > exponent_cap {
          exponent = exponent_cap
        }
      }
      i = i + 1
    }
    if exponent_negative {
      exponent = -exponent
    }
  }
  let mut first = 0
  while first < digits.length() && digits[first] == 0 {
    first = first + 1
  }
  if first == digits.length() {
    return Some(0L)
  }
  let mut last = digits.length() - 1
  while digits[last] == 0 {
    last = last - 1
  }
  let shift = exponent -
    fractional.to_int64() +
    (digits.length() - 1 - last).to_int64()
  let significant = last - first + 1
  if shift < 0L || significant.to_int64() + shift > 19L {
    return None
  }
  let minimum = if negative {
    -9223372036854775808L
  } else {
    -9223372036854775807L
  }
  let quotient = minimum / 10L
  let remainder = -(minimum % 10L)
  let mut value = 0L
  let mut pos = first
  let end = last + 1 + shift.to_int()
  while pos < end {
    let digit = if pos <= last { digits[pos].to_int64() } else { 0L }
    if value < quotient || (value == quotient && digit > remainder) {
      return None
    }
    value = value * 10L - digit
    pos = pos + 1
  }
  Some(if negative { value } else { -value })
}

///|
/// 从 JSON 对象里取一个字符串。
fn json_string(m : Map[String, Json], key : String) -> String? {
  match m.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// 从 JSON 对象里取一个布尔值。
fn json_bool(m : Map[String, Json], key : String) -> Bool? {
  match m.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
/// 包装 `@json.parse`，把 ParseError 转成可放进 `HistoryError` 的文本。
fn parse_json(text : StringView) -> Result[Json, String] {
  let parsed = @json.parse(text) catch {
    _ => return Err("不是合法的 JSON")
  }
  // core/json preserves large integer reprs, but decimal/exponent fast paths
  // may omit them. Parse a shape-identical tree with numeric tokens quoted to
  // recover every lexeme; only original Number nodes receive the source text.
  let quoted = @json.parse(quote_json_numbers(text)) catch {
    _ => return Err("不是合法的 JSON")
  }
  Ok(restore_number_reprs(parsed, quoted))
}

///|
fn quote_json_numbers(text : StringView) -> String {
  let sb = StringBuilder()
  let mut i = 0
  let mut chunk = 0
  let mut in_string = false
  let mut escaped = false
  while i < text.length() {
    let c = text[i]
    if in_string {
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        in_string = false
      }
      i = i + 1
    } else if c == '"' {
      in_string = true
      i = i + 1
    } else if c == '-' || (c >= '0' && c <= '9') {
      sb.write_view(text[chunk:i])
      let start = i
      i = i + 1
      while i < text.length() {
        let digit = text[i]
        if (digit >= '0' && digit <= '9') ||
          digit == '.' ||
          digit == 'e' ||
          digit == 'E' ||
          digit == '+' ||
          digit == '-' {
          i = i + 1
        } else {
          break
        }
      }
      sb.write_char('"')
      sb.write_view(text[start:i])
      sb.write_char('"')
      chunk = i
    } else {
      i = i + 1
    }
  }
  sb.write_view(text[chunk:])
  sb.to_string()
}

///|
fn restore_number_reprs(parsed : Json, source : Json) -> Json {
  match (parsed, source) {
    (Number(value, ..), String(text)) => Json::number(value, repr=text)
    (Object(values), Object(texts)) => {
      let out : Map[String, Json] = Map([])
      for key, value in values {
        out[key] = match texts.get(key) {
          Some(raw) => restore_number_reprs(value, raw)
          None => value
        }
      }
      Json::object(out)
    }
    (Array(values), Array(texts)) => {
      let out : Array[Json] = []
      for i, value in values {
        out.push(restore_number_reprs(value, texts[i]))
      }
      Json::array(out)
    }
    _ => parsed
  }
}

///|
/// 解析 `kind` 字段：`{"tag":"Write","value":1}` 这种带 tag 的对象。
fn parse_kind(j : Json?) -> Result[OpKind, String] {
  match j {
    Some(Object(m)) =>
      match json_string(m, "tag") {
        Some(tag) =>
          match tag {
            "Write" =>
              match json_int(m, "value") {
                Some(v) => Ok(Write(v))
                None => Err("Write 缺少整数 value 字段")
              }
            "Read" => Ok(Read)
            "Cas" =>
              match (json_int(m, "expected"), json_int(m, "new")) {
                (Some(e), Some(n)) => Ok(Cas(e, n))
                _ => Err("Cas 缺少整数 expected/new 字段")
              }
            "Append" =>
              match json_int(m, "value") {
                Some(v) => Ok(Append(v))
                None => Err("Append 缺少整数 value 字段")
              }
            "Pop" => Ok(Pop)
            other => Err("未知的操作 tag: " + other)
          }
        None => Err("kind 缺少 tag 字段")
      }
    _ => Err("kind 必须是对象")
  }
}

///|
/// 解析 `result` 字段：`{"tag":"Value","value":2}` 这种带 tag 的对象。
fn parse_result(j : Json?) -> Result[OpResult, String] {
  match j {
    Some(Object(m)) =>
      match json_string(m, "tag") {
        Some(tag) =>
          match tag {
            "Ok" => Ok(OpResult::Ok)
            "Value" =>
              match json_int(m, "value") {
                Some(v) => Ok(Value(v))
                None => Err("Value 缺少整数 value 字段")
              }
            "Bool" =>
              match json_bool(m, "value") {
                Some(b) => Ok(Bool(b))
                None => Err("Bool 缺少布尔 value 字段")
              }
            "Empty" => Ok(Empty)
            "Nil" => Ok(Nil)
            other => Err("未知的结果 tag: " + other)
          }
        None => Err("result 缺少 tag 字段")
      }
    _ => Err("result 必须是对象")
  }
}

///|
/// 解析一行 JSONL，失败时带上行号（从 1 开始）。
fn parse_op_line(
  line : StringView,
  line_no : Int32,
) -> Result[Operation, HistoryError] {
  match parse_json(line) {
    Err(reason) => Err(BadLine(line_no, reason))
    Ok(Object(m)) =>
      match
        (
          json_int(m, "id"),
          json_int(m, "process"),
          json_int64(m, "start"),
          json_int64(m, "end"),
        ) {
        (Some(id), Some(process), Some(start), Some(end)) =>
          match (parse_kind(m.get("kind")), parse_result(m.get("result"))) {
            (Result::Ok(kind), Result::Ok(result)) =>
              Result::Ok(Operation::{ id, process, kind, result, start, end, })
            (Err(e), _) => Err(BadLine(line_no, e))
            (_, Err(e)) => Err(BadLine(line_no, e))
          }
        _ =>
          Err(
            BadLine(line_no, "缺少或非法的 id/process/start/end 字段"),
          )
      }
    Ok(_) => Err(BadLine(line_no, "每行必须是一个 JSON 对象"))
  }
}

///|
/// 解析整段 JSONL 文本。
///
/// 规则：
/// - 按 `\n` 切行；空行（含只有空白的行）跳过，但**行号照常累加**，
///   这样报错位置与编辑器里的行号一致。
/// - 首行行首的一个 UTF-8 BOM（U+FEFF）被剥掉。Windows 记事本「另存为
///   UTF-8」、PowerShell 的 `Out-File -Encoding utf8` / `>` 重定向、部分
///   日志管道都会写这个字节。它不是 JSON 的一部分，却会让首行的
///   `@json.parse` 失败，把整份**合法**历史判成数据错误 —— 这条路径在
///   Windows 上非常常见。与 `recall` 的 `ReviewLog::from_jsonl` 同口径。
///   只剥**一个**、且只在**首行**：出现在其它位置时它是数据本身的一部分
///   （或文件被拼接坏了），必须照常报错。
/// - 任何一行不合法就立刻返回 `Err(BadLine(行号, 原因))`，不做部分成功的静默丢弃。
///
/// 签名保留 `raise` 以匹配契约（调用方可以写 `catch`），实现本身不抛异常，
/// 错误一律通过 `Result` 返回。
pub fn History::from_jsonl(
  text : StringView,
) -> Result[History, HistoryError] raise {
  let lines = text.split("\n").collect()
  let ops : Array[Operation] = []
  let mut failure : HistoryError? = None
  let mut line_no = 0
  for raw in lines {
    line_no = line_no + 1
    if failure.is_none() {
      let trimmed = raw.trim()
      // BOM 可能被行首空白推到 trim 结果的开头，所以在 trim 之后检测。
      let line : StringView = if line_no == 1 && trimmed.has_prefix("\u{FEFF}") {
        trimmed[1:trimmed.length()]
      } else {
        trimmed
      }
      // 剥完 BOM 后可能变成空行（例如文件只有 BOM），此时按空行处理。
      if line.trim().length() > 0 {
        match parse_op_line(line, line_no) {
          Result::Ok(op) => ops.push(op)
          Err(e) => failure = Some(e)
        }
      }
    }
  }
  match failure {
    Some(e) => Err(e)
    None => Result::Ok({ operations: ops, })
  }
}
