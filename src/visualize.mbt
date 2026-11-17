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
/// 时间戳 -> 列号。
///
/// 全程走 Double，不能用 Int64 直接算 `rel * width`：画布只有几十列，但
/// 中间量 `rel * 48` 在时间跨度超过 `Int64::MAX / 48`（≈1.9e17，纳秒时钟
/// 约 6 年）时回绕，列号变成垃圾值，把后发生的操作画到最左边；`span =
/// tmax - tmin` 在时间戳接近 Int64 两端时本身也会回绕成负数。Double 对
/// ≤2^53 的时间戳精确、更大的值只有 ~1e-16 的相对误差（对 0..width 的
/// 列号毫无影响），减法保序，因此列号在**任何**合法输入下保持先后顺序。
///
/// `span <= 0`（真实跨度超出 Int64 或全部同刻）时按绝对时间戳饱和降级：
/// 列号的绝对含义失效，但「有界 + 单调」两条性质仍然成立——这是跨度信息
/// 已经丢失后的最好结果，不引入新的静默错误。
fn col_of(t : Int64, tmin : Int64, span : Int64, width : Int32) -> Int32 {
  let denom : Double = if span <= 0L { 1.0 } else { span.to_double() }
  let rel : Double = t.to_double() - tmin.to_double()
  let scaled = rel / denom * width.to_double()
  if scaled <= 0.0 {
    0
  } else if scaled >= width.to_double() {
    width
  } else {
    scaled.to_int()
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
///
/// 任何 `start > end` 的操作都会让「时间轴」这个概念本身不成立：它是把时间戳
/// 映射到列号的单调函数，而倒序区间没有可映射的位置。此时**不画**，改为一句
/// 明确的说明（2026-11-17 审计 LC-3）。
///
/// 旧实现在这种输入上仍然照画：`tmin=100 / tmax=0` 让轴标签变成
/// `[100..0]`、`span < 0` 触发 `col_of` 的饱和降级，于是同一段输出里既有
/// 「时间 [100..0]」又有一条画在 0 列的横条 —— 数字全对、图自相矛盾，
/// 与上一轮 LC-D2（列号 Int64 回绕）同族。
///
/// 注意这只改**渲染**，不改判定：`start > end` 的退出码仍由 `check` 的
/// `Unknown`（3）决定，`docs/exit-codes.md` 的契约一个字都不动。
fn render_ops(ops : Array[Operation], scale : Int32) -> String {
  if ops.length() == 0 {
    return "(空历史)\n"
  }
  for op in ops {
    if op.start > op.end {
      return "（区间非法：存在 start > end 的操作，时间轴不成立，已省略）\n"
    }
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
  // 每个进程按 (start, id) 排序（compare_ops 用显式三分支，避免减法溢出）
  let rows : Array[RowLayout] = []
  let mut max_w = 1
  for p in procs {
    let mine : Array[Operation] = []
    for op in ops {
      if op.process == p {
        mine.push(op)
      }
    }
    mine.sort_by(compare_ops)
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
/// 二分：`ends` 里**严格小于** `x` 的元素个数（`ends` 必须已升序）。
fn count_ends_before(ends : Array[Int64], x : Int64) -> Int32 {
  let mut lo = 0
  let mut hi = ends.length()
  while lo < hi {
    let mid = lo + (hi - lo) / 2
    if ends[mid] < x {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo
}

///|
/// 见证子集里成立的**有向**时间约束总数（`a != b && a.end < b.start`）。
///
/// 与 `order_facts` 的截断扫描不同，这里不做 O(k²) 的两两比较：把全部 `end`
/// 排序后，对每条操作 `b` 二分出「有多少条 `end < b.start`」再求和，
/// 复杂度 O(k log k)、额外内存 O(k)。这样即使扫描被截断，也能报出**真实**
/// 总数，而不是把「扫描前缀里的命中数」冒充成总数。
///
/// `end < start` 的非法区间在 `check` 入口就被拦掉了；这里仍按定义减掉操作
/// 自身，免得它把自己算成一条事实（`order_facts` 收到的是各入口筛过的操作，
/// 但这是一条纯函数，不该依赖调用方的保证）。
fn count_order_facts(ops : Array[Operation]) -> Int64 {
  let ends : Array[Int64] = []
  for op in ops {
    ends.push(op.end)
  }
  ends.sort()
  let mut total = 0L
  for op in ops {
    let mut c = count_ends_before(ends, op.start).to_int64()
    if op.end < op.start {
      c = c - 1L
    }
    total = total + c
  }
  total
}

///|
/// 列出见证子集里所有「a 在 b 之前完成」的硬顺序。
///
/// **输出必须与见证规模脱钩。** 顺次执行的历史里每一对都满足 `happens_before`，
/// 事实数因此是 O(k²)：`gen --processes 4 --ops 2400 --inject` 的见证子集 k=7717，
/// 成对事实约 5900 万行，`visualize` 会先把 wasm 堆撑爆、再以
/// `RuntimeError: unreachable`（tlsf/prepareSize）退出——一条诊断命令在输入完全
/// 合法时崩溃，比不输出更糟。所以这里同时给**列出的条数**和**扫描的对数**设上界，
/// 并在截断时明写发生了什么（静默截断同样是错的）。
///
/// 截断摘要里的三个数字必须各自为真（2026-11-13 审计 D1）：
///
/// - 「扫描了多少对」= `scan_limit`，是扫描上界；
/// - 「扫描范围内成立多少条」= 前缀命中数，**不是**整个子集的条数；
/// - 「整个子集共有多少条」= `count_order_facts`，O(k log k) 算出。
///
/// 旧实现只报前两个，并把前缀命中数写成「共 N 条时间约束成立」。实测 507 条
/// 操作的见证子集（真值 256542）被报成 19137——与同一段输出里的
/// 「见证子集：507 / 600」自相矛盾，读者据此判断规模会差 13 倍。
pub fn order_facts(ops : Array[Operation]) -> String {
  let fact_limit = 20
  let scan_limit = 20_000
  let sb = StringBuilder()
  let n = ops.length()
  let mut shown = 0
  let mut found = 0
  let mut scanned = 0
  let mut stop = false
  let mut i = 0
  while i < n && !stop {
    let a = ops[i]
    let mut j = 0
    while j < n && !stop {
      let b = ops[j]
      // `scanned` 的单位必须和同一句里的「n(n-1) 对有向组合」一致：
      // 只数**去重有序对**，`i == j` 的自比较不算「一对」（2026-11-17 审计 LC-10）。
      // 旧实现把 `scanned += 1` 写在 `a != b` 判定之外，于是「已扫描 20000 对」
      // 实际只覆盖 19859 个真正的有序对，读者无法用它重算 `found`；
      // 实测同一句里 `found` 报 120、按「前 20000 个去重对」独立重算是 259。
      if a != b {
        if happens_before(a, b) {
          found = found + 1
          if shown < fact_limit {
            shown = shown + 1
            sb.write_string("    · ")
            sb.write_string(op_summary(a))
            sb.write_string("(proc \{a.process}) 先于 ")
            sb.write_string(op_summary(b))
            sb.write_string("(proc \{b.process})：\{a.end} < \{b.start}\n")
          }
        }
        scanned = scanned + 1
        if scanned >= scan_limit {
          stop = true
        }
      }
      j = j + 1
    }
    i = i + 1
  }
  if stop {
    let pairs = n.to_int64() * (n - 1).to_int64()
    let actual = count_order_facts(ops)
    sb.write_string(
      "    …（输出已截断：见证子集 \{n} 个操作共 \{pairs} 对有向组合；已扫描 \{scanned} 对，",
    )
    sb.write_string("其中 \{found} 条时间约束成立。")
    sb.write_string(
      "该子集实际共有 \{actual} 条时间约束，这里只列出前 \{shown} 条；",
    )
    sb.write_string(
      "其余成对顺序由见证子集的 `end < start` 关系直接决定，可按 `--json` 的见证 id 逐对核对）\n",
    )
  } else if found > shown {
    // 扫描完整，`found` 本身就是子集真值；仍然用 count_order_facts 复核一遍，
    // 两个不同算法的结果必须一致（截断分支用的是它，这里不能换口径）。
    let actual = count_order_facts(ops)
    sb.write_string(
      "    …（输出已截断：该子集共 \{actual} 条时间约束，只列出前 \{shown} 条；",
    )
    sb.write_string(
      "其余由见证子集的 `end < start` 关系直接决定）\n",
    )
  }
  sb.to_string()
}
