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
///
/// 走 `group_by_process` 的一次遍历实现：旧写法对每个操作线性扫一遍「已见过的
/// 进程号」，是 O(操作数 × 进程数)（2026-11-21 审计 LC-24）。
pub fn process_ids(history : History) -> Array[Int32] {
  let (procs, _) = group_by_process(history.operations)
  procs
}

///|
/// 时间轴最多画多少行（= 多少个进程）。
///
/// 行数是 `visualize` 输出里唯一**会随历史规模线性增长**的维度：每行一个历史
/// 里出现过的进程，`gen --processes 100000 --ops 1` 于是产出 100004 行 / 7.1 MB。
/// 画布总尺寸是 `行数 × (列数 + 标签宽)`，两个维度都不设上界时输出随输入增长，
/// 一条诊断命令会在完全合法的历史上下不出东西（2026-11-24 审计 LC-31）。
pub const TIMELINE_MAX_ROWS : Int32 = 64

///|
/// 时间轴每行最多画多少列。
///
/// 列数由「该进程有多少个操作」决定：顺次执行的 5000 个操作要塞进 5000 根横条，
/// 每根至少 `label + 2` 列，于是单行宽度 ≈ 30000 列。行数还有上界时，总输出仍
/// 是 `行数上限 × 单行宽度` —— 一个「1 个胖进程 + 上万个瘦进程」的历史就能让
/// 输出爆到几百 MB（实测 7000 个操作 → 84.5 MB）。两个维度必须同时有上界。
///
/// **这个上界只约束「横条行」**（承载操作数据的那几行）：它们的 `cells.length()`
/// 永不超过本值。轴线不受约束 —— 它在 `+`/`-` 填充到画布右端之后还要追加
/// `> 时间 [tmin..tmax]` 的说明，总长会超出本值（实测 512 列画布对应 529 列的
/// 轴线）。轴线只是坐标刻度、不承载操作数据，若把说明文字也算进本上界，小历史的
/// 时间范围就会被截成读不出来的半截数字。见 `layout_row` 的文档。
pub const TIMELINE_MAX_COLS : Int32 = 512

///|
/// 见证子集的操作清单最多列多少行。
///
/// 清单是「一个操作一行」，见证子集最大可达整份历史：`--ops 24000` 的违规历史
/// 会让 `check` 打出两万多行。与时间轴同口径：上界不得随见证规模增长，截断必须
/// 明写，完整字段由 `check --json` 的 `witness` 数组承载。
pub const WITNESS_LIST_MAX_LINES : Int32 = 200

///|
/// `check --json` 的 `witness` 数组最多序列化多少个操作。
///
/// **为什么 JSON 出口也要上界**（LC-37 续修）：`witness` 条数严格等于历史操作数，
/// 每条是一个六字段对象。实测 `check --json` 在 51/151/401 条操作的历史上分别
/// 输出 3540/10644/28644 字节，线性增长。JSON 是给程序消费的出口，**更**怕无界 ——
/// 下游解析器会被一份上亿操作的 `witness` 直接打死。
///
/// 曾经 `EXPL_PREFIX_MAX_LINES` 的文档写「完整数据由 `check --json` 的 `witness`
/// 数组承载，那里不受此限」，等于用一行注释把「输出随输入线性增长」合法化了。
/// 这条红线本项目已经判过四次（LC-31 时间轴行列、LC-32 minimize 清单、LT35
/// decode、CB-1/CB-2 复杂度），JSON 不是豁免理由。
///
/// **截断只发生在序列化这一步**：内存里的 `Violation.ops` 保持完整 —— `minimize`
/// 的删除复验、`witness_ok` 的复现检查都读 `ops` 本身，砍了它们会静默失效。
/// 被截断时 JSON 额外输出 `witness_total`（真实条数）与 `witness_truncated`，
/// 未截断时这两个键不出现（`API.md` §7.1 的四种形状逐字节不变）。
///
/// 取值与 `WITNESS_LIST_MAX_LINES` 一致，这样「文本清单列了前 N 条」与
/// 「JSON 给了前 N 条」对得上同一个 N，读者不会在两处看到不同的截断点。
pub const WITNESS_MAX_ENTRIES : Int32 = 200

///|
/// 单个进程一行的横条布局结果（内部实现细节，故 `priv`）
///
/// `undrawn` / `clipped` 是**截断记账**，不是布局细节：它们决定时间轴末尾要不要
/// 明写「这一行还有东西没画出来」。静默截断与不截断一样坏——读者会把「画出来的
/// 部分」当成「全部」。
priv struct RowLayout {
  // 每个元素是一条「并列子行」（lane）的 cells。
  //
  // 同一进程的操作**可以并发**（区间重叠即并发，与进程号无关 —— README:109），
  // 所以横向位置必须**只**由时间戳决定；重叠的操作改为画在叠起来的 lane 上。
  // 旧实现只有一行、靠「游标」把重叠的横条横向推开，于是把并发渲染成了先后
  // （2026-11-26 审计 LC-34）。
  lanes : Array[Array[Char]]
  width : Int32
  // 整条横条落在列宽上限之外、一个字符都没画出来的操作数
  undrawn : Int32
  // 横条画了，但（文字或右端）被列宽上限截断的操作数
  clipped : Int32
}

///|
/// 给一个进程内的操作分配列位置，写出横条。
///
/// ## 横向位置只由时间戳决定（LC-34）
///
/// 每一根横条的左端列号 = `col_of(op.start)`，右端 = `col_of(op.end)`（放不下
/// 文字时向右撑到 `label + 2`）。**没有游标**：横条之间不会互相推挤。
///
/// 为什么必须这样：时间轴是 `check` 结论的视觉证据，读者从图上读出的顺序约束
/// 必须真的成立 —— 「A 画在 B 左边」就该蕴含 `happens_before(A, B)`。旧实现用
/// 游标 `start_col = max(want_start, cursor)` 把同一进程的横条强行串行排开，
/// 于是 `[0,1000]` 与 `[400,600]` 这种**完全并发**的一对被画成一前一后，图说谎
/// 而 `check` 说真话。
///
/// ## 重叠用并列子行（lane）表示
///
/// 同一进程的操作可以并发（区间重叠即并发，与进程号无关）：按 `(start, id)`
/// 升序依次分配「右端最小的那条 lane」，放不下就新开一条。于是并发看得见（叠起来），
/// 而顺序也看得见（串行的横条落在同一条 lane 上、横向分离）。
///
/// **宽度上界只约束「横条行」**：每条 lane 画出来的 `cells.length()` 永不超过
/// `max_cols`。横条按 `(start, id)` 升序排过，位置单调不减，所以一旦某一根
/// 再也放不下内容格（`inner < 0`，见下方内层计算），后面所有横条只会更靠右，
/// 直接停止并记入 `undrawn`。
///
/// 注意这个上界**不覆盖轴线**：轴线由 `render_ops_bounded` 在 `+` 与 `-`
/// 填充到画布右端之后，再追加 `> 时间 [tmin..tmax]` 的说明文字，因此轴线总长
/// 是 `label_w + 1 + (max_cols + 2) + 说明文字长度`，会**超过** `max_cols`。
/// 轴线不承载操作数据（它只是坐标刻度），不属于「输出随历史规模增长」那一族，
/// 所以有意留在上界之外；若把说明也算进 `max_cols`，小历史的时间范围就会被
/// 截断成读不出来的半截数字。
fn layout_row(
  ops : Array[Operation],
  tmin : Int64,
  span : Int64,
  scale : Int32,
  max_cols : Int32,
) -> RowLayout {
  let lanes : Array[Array[Char]] = []
  // 每条 lane 已占到的**几何**右边界（最后一根横条的 end_col），用于渲染不重叠。
  let geo_ends : Array[Int32] = []
  // 每条 lane 上最后一根横条的**时间** end，用于判定「时间上是否重叠」。
  let time_ends : Array[Int64] = []
  let mut drawn = 0
  let mut clipped = 0
  let last_col = max_cols - 1
  let mut max_w = 0
  let mut i = 0
  while i < ops.length() {
    let op = ops[i]
    let label = op_summary(op)
    let need = label.length() + 2 // 左右方括号
    let want_start = col_of(op.start, tmin, span, scale)
    let want_end = col_of(op.end, tmin, span, scale)
    let start_col = want_start
    // 选一条 lane。
    //
    // 判据只有一条，且它是**正确性**判据：`time_ends[lane] <= op.start` ——
    // 上一条横条的时间结束不晚于这一条的时间开始，二者不并发，才可以并排。
    // 重叠（真并发）必须叠到不同的 lane 上，否则「左 ⇒ 先」被破坏（LC-34）。
    //
    // 放不下文字时**允许几何重叠**：`]` 会盖住上一根的尾巴。这是有意的取舍 ——
    // 横向位置必须忠实于时间戳，宁可字符互相覆盖也不能为了好看把横条推开
    // （推开就是伪造顺序）。若改用「几何放得下」作判据，`[0,10]`/`[10,20]`
    // 这种顺次历史会因为标签撑宽而被拆成多层，串行顺序反而看不出来。
    //
    // 多条 lane 都可用时取几何右端最小的那条，让图尽量紧凑。
    let mut lane = -1
    let mut li = 0
    while li < lanes.length() {
      if time_ends[li] <= op.start {
        if lane < 0 || geo_ends[li] < geo_ends[lane] {
          lane = li
        }
      }
      li = li + 1
    }
    let would_create = lane < 0
    // **列宽上界的真正闸门**。
    //
    // 横向位置只由时间戳决定之后，多根横条会落到同一列（`col_of` 的结果上限
    // 就是 `scale`），此时横条被**依次**追加到 cells 末尾，行长度随操作数线性
    // 增长。只看 `start_col` 会漏判：`--ops 1200` 实测单行 6009 列，而
    // `TIMELINE_MAX_COLS = 512`。所以闸门必须看**这一行画上去之后的尾部**。
    let cur_len = if would_create { 0 } else { lanes[lane].length() }
    let base = if cur_len > start_col { cur_len } else { start_col }
    // 连 `[]` 都放不下（左括号已经到/越过最后一列）：整根不画，停止。
    //
    // `base` 与 `start_col` 都只增不减，后面只会更靠右，所以直接 break；
    // 少画的条数由 `undrawn = 总数 - drawn` 记账（含本根与之后全部）。
    if base + 1 > last_col {
      break
    }
    // 右边界：既要覆盖真实结束时间，又要放得下文字
    let min_end = start_col + need - 1
    let mut end_col = if want_end > min_end { want_end } else { min_end }
    if end_col < base + need - 1 {
      end_col = base + need - 1
    }
    // `end_col` 不能低于 `base`：否则 `inner` 为负、`]` 会被 push 在上一根的
    // 尾巴之后，把 cells 顶出 `max_cols`。
    if end_col < base + 1 {
      end_col = base + 1
    }
    if end_col > last_col {
      // 右端**超出**最后一列：钳到 last_col，横条画了但有损 —— 如实记账。
      //
      // 判据必须是 `>` 而不是 `>=`：`end_col == last_col` 时 `]` 正好落在最后一列，
      // 整根横条完整画出来了，不是截断。写成 `>=` 会把每行一根完整横条错记成
      // 被截断（实测 4 进程 × 120 操作恒报 `1 个横条被行尾截断`，而那一根其实完整）。
      end_col = last_col
      clipped = clipped + 1
    }
    if would_create {
      lanes.push([])
      geo_ends.push(-1)
      time_ends.push(-9223372036854775807L)
      lane = lanes.length() - 1
    }
    let cells = lanes[lane]
    while cells.length() < start_col {
      cells.push(' ')
    }
    // 若本根左端落在上一根尾巴之前（时间相邻但标签撑宽），从那里接上
    if cells.length() < base {
      while cells.length() < base {
        cells.push(' ')
      }
    }
    cells.push('[')
    let chars = label.to_array()
    // 内层要填多少格，由**目标右端**反推。
    //
    // `end_col` 是 `]` 的**下标**：压完 `]` 后 `cells.length()` 必须等于
    // `end_col + 1`。当前 `cells.length()` 已经包含刚 push 的 `[`，所以
    // 内层格数 = `end_col + 1 - 1 - cells.length() = end_col - cells.length()`。
    //
    // 写成 `end_col + 1 - cells.length()` 会多填一格，压完 `]` 后长度变成
    // `end_col + 2` —— 钳到 `last_col` 的那一根于是在 513 列收尾，把单行宽度
    // 顶出 `max_cols`（实测 170 个 Reader 时 `cells = 513`，而上限是 512）。
    //
    // 关键不变量：`end_col <= last_col`（上面钳过），所以压完 `]` 后
    // `cells.length() <= max_cols` —— 单行宽度的硬上界由这里保证。
    let inner = end_col - cells.length()
    if inner < 0 {
      // `cells` 已经越过目标右端：这一根放不下任何内容格，回滚 `[` 并停止。
      // 不回滚会留下没有配对的括号。
      let _ = cells.pop()
      break
    }
    let mut k = 0
    while k < inner {
      if k < chars.length() {
        cells.push(chars[k])
      } else {
        cells.push(' ')
      }
      k = k + 1
    }
    cells.push(']')
    geo_ends[lane] = cells.length() - 1
    time_ends[lane] = op.end
    if cells.length() > max_w {
      max_w = cells.length()
    }
    drawn = drawn + 1
    i = i + 1
  }
  if lanes.length() == 0 {
    lanes.push([])
  }
  { lanes, width: max_w, undrawn: ops.length() - drawn, clipped, }
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
  render_ops_bounded(ops, scale, TIMELINE_MAX_ROWS, TIMELINE_MAX_COLS)
}

///|
/// 时间轴渲染本体，带显式上界（`render_ops` 用默认上界调它）。
///
/// **契约**：输出尺寸与历史规模无关，且每行的上界可精确给出：
///
/// - **横条行**：`标签宽 + 1 + max_cols`；
/// - **轴线**：`标签宽 + 1 + (max_cols + 2) +「> 时间 [a..b]」`，比横条行多
///   `2 + 说明文字长度`（实测 512 列画布 → 535 列轴线，而横条行是 521 列）。
///   说明文字是两个 `Int64` 的十进制位数加固定前缀，同样与规模无关。
///
/// 所以总尺寸 ≤ `(max_rows + 1) × (标签宽 + 1 + max_cols + 2 + 说明长度上限) + 常量`
/// （外加至多 9 行截断说明）。截断时必写清「几个进程没画」「哪些行有操作没画」
/// 「完整数据去哪拿」。
///
/// 旧版这条契约写成 `max_rows × (max_cols + 标签宽 + 3)`，低估了轴线 12 列以上；
/// 只当粗略量级的话无伤，但作为「精确上界」它不成立，故按上表改正。
///
/// 为什么两个维度都要上界：只限行数时单行宽度仍随「某进程的操作数」增长
/// （5000 个顺次操作 ≈ 30000 列），只限列宽时行数仍随进程数增长
/// （100000 进程 → 100004 行）。任缺一个都是无上界（LC-31）。
fn render_ops_bounded(
  ops : Array[Operation],
  scale : Int32,
  max_rows : Int32,
  max_cols : Int32,
) -> String {
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
  // 进程列表 + 分桶：一次遍历，O(操作数 + 进程数·log 进程数)。
  // 旧写法在这里是「每个操作线性扫一遍已见进程号」+「每个进程再扫一遍全部
  // 操作」，等价 O(操作数 × 进程数)（2026-11-21 审计 LC-24）。
  let (procs, groups) = group_by_process(ops)
  // 行上界：只给**前** max_rows 个进程布局（procs 已升序，故截断点确定）。
  // 没画的行连布局都不做——它们的 cells 数组也是一份按操作数增长的真实内存，
  // 只省输出不省内存的话，10 万进程的历史照样把堆占满。
  let row_count = if procs.length() > max_rows {
    max_rows
  } else {
    procs.length()
  }
  // 每个进程按 (start, id) 排序（compare_ops 用显式三分支，避免减法溢出）
  let rows : Array[RowLayout] = []
  let mut max_w = 1
  for i in 0..<row_count {
    let mine = groups[i]
    mine.sort_by(compare_ops)
    let layout = layout_row(mine, tmin, span, scale, max_cols)
    if layout.width > max_w {
      max_w = layout.width
    }
    rows.push(layout)
  }
  // 标签列宽（只按画出来的行算：没画的行的进程号不该把整张图推宽）
  let mut label_w = 0
  for i in 0..<row_count {
    let l = "proc \{procs[i]}".length()
    if l > label_w {
      label_w = l
    }
  }
  label_w = label_w + 2
  // 组装。每个进程占 `lanes.length()` 行：第一行带进程标签，其余行留空对齐，
  // 这样读者一眼能看出哪几根横条是并发（叠在同一进程的多行上）。
  let sb = StringBuilder()
  let mut r = 0
  while r < row_count {
    let label = "proc \{procs[r]}"
    let layout = rows[r]
    let lanes = layout.lanes
    let mut ln = 0
    while ln < lanes.length() {
      if ln == 0 {
        sb.write_string(pad_right(label, label_w))
      } else {
        sb.write_string(repeat_char(' ', label_w))
      }
      sb.write_char('|')
      let cells = lanes[ln]
      let mut c = 0
      while c < max_w {
        if c < cells.length() {
          sb.write_char(cells[c])
        } else {
          sb.write_char(' ')
        }
        c = c + 1
      }
      sb.write_char('\n')
      ln = ln + 1
    }
    r = r + 1
  }
  // 底部时间轴
  sb.write_string(repeat_char(' ', label_w))
  sb.write_char('+')
  sb.write_string(repeat_char('-', max_w + 2))
  sb.write_string("> 时间  [\{tmin}..\{tmax}]\n")
  append_timeline_truncation_notes(sb, procs, rows, row_count, max_cols)
  sb.to_string()
}

///|
/// 时间轴的截断记账：两类事实各写一句，且两句的**行数都有上界**。
///
/// 只写「已截断」而不写「截了多少」等于让读者自己猜；把每行都列一遍则又把
/// 输出拉回 O(进程数)。所以明细最多列 8 行，其余折成计数。
fn append_timeline_truncation_notes(
  sb : StringBuilder,
  procs : Array[Int32],
  rows : Array[RowLayout],
  row_count : Int32,
  max_cols : Int32,
) -> Unit {
  let omitted_rows = procs.length() - row_count
  if omitted_rows > 0 {
    sb.write_string(
      "（时间轴已截断：历史里共 \{procs.length()} 个进程，只画出前 \{row_count} 个（proc \{procs[0]}..proc \{procs[row_count - 1]}）；其余 \{omitted_rows} 个进程没有对应的行。完整数据见 `lincheck check --json` 的 witness 数组）\n",
    )
  }
  // 列宽截断：先汇总，再列至多 8 行明细
  let mut affected = 0
  let mut undrawn_total = 0
  let mut clipped_total = 0
  for i in 0..<row_count {
    let l = rows[i]
    if l.undrawn > 0 || l.clipped > 0 {
      affected = affected + 1
    }
    undrawn_total = undrawn_total + l.undrawn
    clipped_total = clipped_total + l.clipped
  }
  if affected > 0 {
    sb.write_string(
      "（列宽上限 \{max_cols} 列：共 \{undrawn_total} 个操作整条横条落在上限之外没画出来，\{clipped_total} 个横条被行尾截断；受影响的行 \{affected} 行",
    )
    let mut listed = 0
    let mut i = 0
    while i < row_count && listed < 8 {
      let l = rows[i]
      if l.undrawn > 0 || l.clipped > 0 {
        sb.write_string(
          "\n    · proc \{procs[i]}：未画出 \{l.undrawn} 个、行尾截断 \{l.clipped} 个",
        )
        listed = listed + 1
      }
      i = i + 1
    }
    if affected > listed {
      sb.write_string(
        "\n    · …其余 \{affected - listed} 行同形，不再列出",
      )
    }
    sb.write_string(
      "\n  完整时间戳见 `lincheck check --json` 的 witness 数组）\n",
    )
  }
}

///|
/// 文本时间轴：每行一个进程，操作画成横条
pub fn render_timeline(history : History) -> String {
  render_ops(history.operations, 48)
}

///|
/// 见证子集的操作清单：一行一个操作（`render_violation` 与 CLI 的 `minimize`
/// **共用这一份**）。
///
/// 抽出来的理由是「一个判断只有一处」：CLI 里曾有一份逐字节等价的私有拷贝
/// （`cmd/lincheck/main.mbt` 的 `render_ops_indented`），于是同一个文本形状有
/// 两个实现，上界只能加在一处 —— 而 `minimize` 走的正是没加界的那一份
/// （2026-11-24 审计 LC-32）。
///
/// 行数上界 `WITNESS_LIST_MAX_LINES`：见证子集最大可达整份历史，清单因此必须
/// 与见证规模脱钩，并在截断时写出「共多少、列了多少」。
pub fn render_witness_ops(ops : Array[Operation]) -> String {
  let sb = StringBuilder()
  let shown = if ops.length() > WITNESS_LIST_MAX_LINES {
    WITNESS_LIST_MAX_LINES
  } else {
    ops.length()
  }
  let mut i = 0
  while i < shown {
    sb.write_string("    · 操作 ")
    sb.write_string(ops[i].id.to_string())
    sb.write_string(": ")
    sb.write_string(op_line(ops[i]))
    sb.write_string("\n")
    i = i + 1
  }
  if ops.length() > shown {
    sb.write_string(
      "    …（已截断：见证共 \{ops.length()} 个操作，只列出前 \{shown} 个；其余 \{ops.length() - shown} 个的完整字段见 `lincheck check --json` 的 witness 数组）\n",
    )
  }
  sb.to_string()
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
  sb.write_string(render_witness_ops(sorted))
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
/// 见证子集里成立的**有向**时间约束总数（`i != j && a.end < b.start`）。
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
      // 必须按下标排除自比较：两个位置可以装着完全相同的 Operation。
      // 若按 `a != b` 去重，这些真实有序对会从 scanned 中消失，摘要分母
      // 仍是 n(n-1)，而扫描进度与截断判断却按另一个口径计算。
      if i != j {
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
