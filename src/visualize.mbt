// ============================================================================
// visualize.mbt — 文本时间轴
//
// 把逻辑时间戳归一化到字符列，每个进程一行，操作画成 [......] 横条。
// 同一进程内的操作保证按时间顺序排开、互不覆盖：
// 分配列时用「游标」记住上一根横条的右边界，绝不回退。
// ============================================================================

///|
/// 操作摘要（塞进横条里），例如 Write(1) -> "W=1"、"R->1"
pub fn op_summary(op : Operation) -> String {
  let k = match op.kind {
    Write(v) => "W=\{v}"
    Read => "R"
    Cas(e, n) => "C\{e}>\{n}"
    Append(v) => "A\{v}"
    Pop => "P"
  }
  let r = match op.result {
    Ok => ""
    Value(v) => "->\{v}"
    Bool(true) => "->Y"
    Bool(false) => "->N"
    Empty => "->E"
    Nil => "->?"
  }
  k + r
}

///|
/// 重复一个字符 n 次
pub fn repeat_char(c : Char, n : Int32) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    sb.write_char(c)
    i = i + 1
  }
  sb.to_string()
}

///|
/// 左对齐补空格到 w 列（已足够长则原样返回）
pub fn pad_right(s : String, w : Int32) -> String {
  let n = s.length()
  if n >= w {
    s
  } else {
    s + repeat_char(' ', w - n)
  }
}

///|
/// 取前 n 个码元（超长摘要截断用）
pub fn clip(s : String, n : Int32) -> String {
  if s.length() <= n {
    s
  } else if n <= 0 {
    ""
  } else {
    s.substring(start=0, end=n)
  }
}

///|
/// 时间戳 -> 列号
fn col_of(t : Int64, tmin : Int64, span : Int64, width : Int32) -> Int32 {
  let rel = t - tmin
  let denom : Int64 = if span <= 0L { 1L } else { span }
  let scaled = rel * width.to_int64() / denom
  let c = scaled.to_int()
  if c < 0 {
    0
  } else if c > width {
    width
  } else {
    c
  }
}

///|
/// 收集历史里出现过的进程号（升序去重）
pub fn process_ids(history : History) -> Array[Int32] {
  let out : Array[Int32] = []
  for op in history.operations {
    let mut seen = false
    for p in out {
      if p == op.process {
        seen = true
      }
    }
    if !seen {
      out.push(op.process)
    }
  }
  out.sort()
  out
}

///|
/// 单个进程一行的横条布局结果
struct RowLayout {
  cells : Array[Char]
  width : Int32
}

///|
/// 给一个进程内的操作分配列位置，写出横条
fn layout_row(
  ops : Array[Operation],
  tmin : Int64,
  span : Int64,
  scale : Int32,
) -> RowLayout {
  let cells : Array[Char] = []
  let mut cursor = 0
  for op in ops {
    let label = op_summary(op)
    let need = label.length() + 2 // 左右方括号
    let want_start = col_of(op.start, tmin, span, scale)
    let want_end = col_of(op.end, tmin, span, scale)
    let start_col = if want_start > cursor { want_start } else { cursor }
    // 右边界：既要覆盖真实结束时间，又要放得下文字
    let min_end = start_col + need - 1
    let end_col = if want_end > min_end { want_end } else { min_end }
    // 补齐到 start_col
    while cells.length() < start_col {
      cells.push(' ')
    }
    cells.push('[')
    let chars = label.to_array()
    let mut i = 0
    let inner = end_col - start_col - 1
    while i < inner {
      if i < chars.length() {
        cells.push(chars[i])
      } else {
        cells.push(' ')
      }
      i = i + 1
    }
    cells.push(']')
    cursor = end_col + 2 // 至少空一列
  }
  { cells, width: cells.length(), }
}

///|
/// 渲染全部操作的时间轴（内部实现，ops 可以是子集）
fn render_ops(ops : Array[Operation], scale : Int32) -> String {
  if ops.length() == 0 {
    return "(空历史)\n"
  }
  // 时间范围
  let mut tmin = ops[0].start
  let mut tmax = ops[0].end
  for op in ops {
    if op.start < tmin {
      tmin = op.start
    }
    if op.end > tmax {
      tmax = op.end
    }
  }
  let span = tmax - tmin
  // 进程列表
  let procs : Array[Int32] = []
  for op in ops {
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
  // 每个进程按 (start, id) 排序
  let rows : Array[RowLayout] = []
  let mut max_w = 1
  for p in procs {
    let mine : Array[Operation] = []
    for op in ops {
      if op.process == p {
        mine.push(op)
      }
    }
    mine.sort_by(fn(a, b) {
      if a.start == b.start {
        a.id - b.id
      } else if a.start < b.start {
        -1
      } else {
        1
      }
    })
    let layout = layout_row(mine, tmin, span, scale)
    if layout.width > max_w {
      max_w = layout.width
    }
    rows.push(layout)
  }
  // 标签列宽
  let mut label_w = 0
  for p in procs {
    let l = "proc \{p}".length()
    if l > label_w {
      label_w = l
    }
  }
  label_w = label_w + 2
  // 组装
  let sb = StringBuilder()
  let mut r = 0
  while r < procs.length() {
    let label = "proc \{procs[r]}"
    sb.write_string(pad_right(label, label_w))
    sb.write_char('|')
    let layout = rows[r]
    let mut c = 0
    while c < max_w {
      if c < layout.cells.length() {
        sb.write_char(layout.cells[c])
      } else {
        sb.write_char(' ')
      }
      c = c + 1
    }
    sb.write_char('\n')
    r = r + 1
  }
  // 底部时间轴
  sb.write_string(repeat_char(' ', label_w))
  sb.write_char('+')
  sb.write_string(repeat_char('-', max_w + 2))
  sb.write_string("> 时间  [\{tmin}..\{tmax}]\n")
  sb.to_string()
}

///|
/// 文本时间轴：每行一个进程，操作画成横条
pub fn render_timeline(history : History) -> String {
  render_ops(history.operations, 48)
}

///|
/// 渲染反例，高亮冲突操作
pub fn render_violation(v : Violation, history : History) -> String {
  let sb = StringBuilder()
  let witness = if v.ops.length() > 0 { v.ops } else { history.operations }
  let total = history.length()
  sb.write_string("✗ 非线性一致（NON-LINEARIZABLE）\n")
  sb.write_string("  见证子集：")
  sb.write_string(witness.length().to_string())
  sb.write_string(" / ")
  sb.write_string(total.to_string())
  sb.write_string(" 个操作\n\n")
  // 时间轴（只画见证子集，避免噪音）
  sb.write_string(render_ops(witness, 48))
  sb.write_string("\n")
  // 逐条列出
  sb.write_string("  冲突操作：\n")
  let sorted = sort_ops_by_id(witness)
  for op in sorted {
    sb.write_string("    · 操作 ")
    sb.write_string(op.id.to_string())
    sb.write_string(": ")
    sb.write_string(op_line(op))
    sb.write_string("\n")
  }
  sb.write_string("\n")
  if v.explanation.length() > 0 {
    sb.write_string("  ")
    sb.write_string(v.explanation)
    sb.write_string("\n")
  }
  if v.depth > 0 {
    sb.write_string("\n  最长一致前缀长度：")
    sb.write_string(v.depth.to_string())
    sb.write_string("\n")
  }
  // 客观事实：哪些操作之间不并发，因此顺序被钉死
  let facts = order_facts(sorted)
  if facts.length() > 0 {
    sb.write_string("\n  时间约束（这些顺序无法调换）：\n")
    sb.write_string(facts)
  }
  sb.to_string()
}

///|
/// 列出见证子集里所有「a 在 b 之前完成」的硬顺序
pub fn order_facts(ops : Array[Operation]) -> String {
  let sb = StringBuilder()
  for a in ops {
    for b in ops {
      if a.id != b.id && happens_before(a, b) {
        sb.write_string("    · ")
        sb.write_string(op_summary(a))
        sb.write_string("(proc \{a.process}) 先于 ")
        sb.write_string(op_summary(b))
        sb.write_string("(proc \{b.process})：\{a.end} < \{b.start}\n")
      }
    }
  }
  sb.to_string()
}
