// ============================================================================
// lc35_clipped_offbyone_test.mbt —— 「行尾截断」的计数不得把完整横条算进去
//
// ## 现象
//
// `visualize` 在超长行末尾写一句截断说明，其中有两个数字：
// 「共 N 个操作整条横条落在上限之外没画出来，M 个横条被行尾截断」。
//
// `M`（clipped）的定义是「横条画了，但右端被列宽上限钳掉」——**有损**的画法。
// 旧实现用 `end_col >= last_col` 判定，而 `end_col == last_col` 时 `]` 正好落在
// 最后一列，那根横条是**完整**画出来的。于是每一行只要有一根横条刚好顶到边界，
// 就会被错记成「被截断」：
//
//     proc 0  |[W=1 ][R->3 ]…[R->3 ][W=1 ]          ← 最后一根完整，`]` 在第 511 列
//     （列宽上限 512 列：共 209 个操作整条横条落在上限之外没画出来，1 个横条被行尾截断；
//         · proc 0：未画出 41 个、行尾截断 1 个）
//
// 实测 4 进程 × 120/200/300 操作三档全部恒报 `1 个横条被行尾截断`，而那个横条
// 在三种规模下都是完整的 —— 说明这个 1 与历史无关，纯粹是判据的边界错位。
//
// ## 危害
//
// 截断说明是「图不可信」的唯一信号。虚报截断会让读者以为有内容被吞掉、
// 转而去看 `check --json` 的原始数据；反过来漏报才是灾难。诚实的记账是这条
// 输出存在的前提（同族：LC-31 的「未画出」计数、`order_facts` 的截断说明）。

///|
/// 单进程 n 个顺次操作的横条，压缩到能被 drawable 是常态。
fn lc35_seq(n : Int32) -> History {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < n {
    ops.push(Operation::{
      id: i,
      process: 0,
      kind: Write(i % 7),
      result: Ok,
      start: i.to_int64() * 10L,
      end: i.to_int64() * 10L + 8L,
    })
    i = i + 1
  }
  History::{ operations: ops, }
}

///|
/// 从截断说明里取出两个数字：`(未画出, 行尾截断)`。
///
/// 不引正则包（`src` 的 `moon.pkg` 没导 `regexp`）：说明的措辞是固定的，
/// 按两个已知锚点扫十进制数字即可。
fn lc35_counts(out : String) -> (Int32, Int32)? {
  let a_mark = "共 "
  let b_mark = " 个操作整条横条落在上限之外没画出来，"
  let c_mark = " 个横条被行尾截断"
  let ia = match out.find(a_mark) {
    Some(i) => i + a_mark.length()
    None => return None
  }
  let ib = match out.find(b_mark) {
    Some(i) => i
    None => return None
  }
  let ic = match out.find(c_mark) {
    Some(i) => i
    None => return None
  }
  // 已经越过 a_mark 的 "个操作…" 段：第二个数字在 ib 与 ic 之间
  let first = lc35_uint(out.substring(start=ia, end=ib))
  let second = lc35_uint(out.substring(start=ib + b_mark.length(), end=ic))
  match (first, second) {
    (Some(a), Some(b)) => Some((a, b))
    _ => None
  }
}

///|
/// 一段纯十进制数字 → `Int32?`
fn lc35_uint(s : String) -> Int32? {
  if s.length() == 0 {
    return None
  }
  let mut v = 0
  for ch in s.to_array() {
    if ch < '0' || ch > '9' {
      return None
    }
    v = v * 10 + (ch.to_int() - '0'.to_int())
  }
  Some(v)
}

///|
/// 画布行里出现的横条数（`[` 的个数，减掉轴标签那一行）。
fn lc35_boxes(out : String) -> Int32 {
  let mut n = 0
  for line in out.split("\n").collect() {
    let s = line.to_owned()
    // 跳过轴标签行（含「时间  [」）
    if s.contains("时间  [") {
      continue
    }
    for ch in s.to_array() {
      if ch == '[' {
        n = n + 1
      }
    }
  }
  n
}

///|
/// **核心断言**：`未画出 + 实画条数 == 历史总数`，且 `clipped` 必须与「真的被压扁
/// 的横条数」一致 —— 不多报。
///
/// 判据不用「clipped 恒为 0」（本形状确实会把最后一根 `W=6` 压成 `W`，那是真截断），
/// 而是**逐根核对**：把画出来的每根横条的文字与 `op_summary` 对照，数出「文字比
/// 应有长度短」的条数，这个数必须等于 `clipped`。
///
/// 旧实现多报 off-by-one（`end_col == last_col` 的完整横条被算成截断），会让
/// 这个等式左边比右边大 1。
test "LC-35: clipped 计数与「真的被压扁的横条数」一致" {
  let total = 300
  let out = render_timeline(lc35_seq(total))
  let (undrawn, clipped) = match lc35_counts(out) {
    Some(p) => p
    None => {
      assert_true(false)
      (0, 0)
    }
  }
  let drawn = lc35_boxes(out)
  // 自洽条件：画出来的 + 没画的 = 全体
  assert_eq(drawn + undrawn, total)
  // 逐根核对：被压扁的条数 == clipped
  assert_eq(lc35_truncated_boxes(out), clipped)
}

///|
/// 数出画布行里「内容不完整」的横条数。
///
/// 判据：横条内层格数 < 该摘要应有的长度。本测试的历史全是 `W=i%7`
/// （摘要 `W=0`..`W=6`，长 3），所以任何内层格数 < 3 的横条都是被压扁的 ——
/// 包括内层为 0 的 `[]`（整条内容被吃掉，只剩空框）。
fn lc35_truncated_boxes(out : String) -> Int32 {
  let mut n = 0
  for line in out.split("\n").collect() {
    let s = line.to_owned()
    if s.contains("时间  [") {
      continue
    }
    let mut start = 0
    let mut found_pipe = false
    for i, ch in s.to_array() {
      if ch == '|' {
        start = i + 1
        found_pipe = true
        break
      }
    }
    if !found_pipe {
      continue
    }
    let content = s.substring(start~)
    let mut open = -1
    let mut c = 0
    for ch in content.to_array() {
      if ch == '[' {
        open = c
      } else if ch == ']' {
        if open >= 0 {
          let inner = c - open - 1
          // 摘要至少有 3 格（`W=n`）；内层不足 3 即内容不完整
          if inner < 3 {
            n = n + 1
          }
        }
        open = -1
      }
      c = c + 1
    }
  }
  n
}

///|
/// 同一份历史、不同规模：`clipped` 不得是一个与历史无关的常数。
///
/// 这条防的是「为了通过上面的测试，把 clipped 无条件写成 0」。真出现截断时
/// 仍必须报出来 —— 但本测试用**只变规模、不变形状**的三档，断言 clipped
/// 保持一致（本形状下恒 0），而不是随规模漂移。
test "LC-35: 行尾截断计数不随规模漂移" {
  for n in [120, 200, 300] {
    let out = render_timeline(lc35_seq(n))
    let (undrawn, clipped) = match lc35_counts(out) {
      Some(p) => p
      None => {
        assert_true(false)
        (0, 0)
      }
    }
    assert_eq(lc35_boxes(out) + undrawn, n)
    // 逐根核对：clipped 必须等于真的被压扁的条数（不得多报 off-by-one）
    assert_eq(lc35_truncated_boxes(out), clipped)
  }
}

///|
/// **硬上界**：任何一行的画布格数都不得超过 `TIMELINE_MAX_COLS`。
///
/// 这条是 LC-31 那条 `line.length() <= 600` 的精确版：600 那档只挡住了
/// 「量级爆炸」（旧实现单行 6009 列），挡不住 512 → 513 这一格的越界。
///
/// 越界的产生方式很隐蔽：横条被钳到 `last_col` 后，内层格数若按
/// `end_col + 1 - cells.length()` 反推，压完 `]` 后长度就成了 `end_col + 2`，
/// 即 513 —— 比上限多一格。实测 170 个 `Read` 时 `cells = 513`。
test "LC-35: 单行画布格数永不超过 TIMELINE_MAX_COLS" {
  // 三档都用「小标签、多操作」把行填满：`W=n` 长 3，`R` 长 1
  for n in [120, 170, 300] {
    let out = render_timeline(lc35_seq(n))
    for line in out.split("\n").collect() {
      let s = line.to_owned()
      // 只检查画布行（带 `|` 的行）
      let mut pipe = -1
      for i, ch in s.to_array() {
        if ch == '|' {
          pipe = i
          break
        }
      }
      if pipe < 0 {
        continue
      }
      let cells = s.length() - pipe - 1
      assert_true(cells <= TIMELINE_MAX_COLS)
    }
  }
  // 另一种标签宽度（`R` 长 1 → need 3），推进节奏不同，同样不得越界
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 200 {
    ops.push(Operation::{
      id: i,
      process: 0,
      kind: Read,
      result: Ok,
      start: 0L,
      end: 0L,
    })
    i = i + 1
  }
  for
    line in render_timeline(History::{ operations: ops, }).split("\n").collect() {
    let s = line.to_owned()
    let mut pipe = -1
    for i, ch in s.to_array() {
      if ch == '|' {
        pipe = i
        break
      }
    }
    if pipe < 0 {
      continue
    }
    assert_true(s.length() - pipe - 1 <= TIMELINE_MAX_COLS)
  }
}

///|
/// **off-by-one 的精确锁**：右端**恰好**落在最后一列的横条不得记成「被截断」。
///
/// 构造法：`A0`（`Append(0)` 的摘要，长 2）→ `need = 4`。所有操作取
/// `start = end = 0`，横向位置完全由 lane 推进决定，第 k 根占 `[4(k-1), 4k-1]`：
///
///   第 128 根：`base = 508`，`end_col = 511 == TIMELINE_MAX_COLS - 1`
///
/// 这一根的 `]` 正好落在最后一列，**完整**画出来了。旧实现用
/// `end_col >= last_col` 判截断，于是 n=128 时报 `1 个横条被行尾截断` ——
/// 而实际被钳掉的只有 n=129 及以后。
///
/// 修复前后实测：
///   - `>=`（旧）：n=128 → clipped = 1（虚报）
///   - `>` （新）：n=128 → 无截断说明（clipped = 0）
test "LC-35: 右端恰好在最后一列的横条不算截断" {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 128 {
    ops.push(Operation::{
      id: i,
      process: 0,
      kind: Append(0),
      result: Ok,
      start: 0L,
      end: 0L,
    })
    i = i + 1
  }
  let out = render_timeline(History::{ operations: ops, })
  // 128 根正好铺满 512 列，一根都不该少
  assert_eq(lc35_boxes_all(out), 128)
  // 宽度恰好顶到上限，但不越界
  for line in out.split("\n").collect() {
    let s = line.to_owned()
    let mut pipe = -1
    for i, ch in s.to_array() {
      if ch == '|' {
        pipe = i
        break
      }
    }
    if pipe < 0 {
      continue
    }
    assert_true(s.length() - pipe - 1 <= TIMELINE_MAX_COLS)
  }
  // 关键：不得虚报截断
  match lc35_counts(out) {
    None => ()
    Some((_, clipped)) => assert_eq(clipped, 0)
  }
}

///|
/// 数画布行里所有横条（含轴行的 `[…]` 也要排除）。
fn lc35_boxes_all(out : String) -> Int32 {
  let mut n = 0
  for line in out.split("\n").collect() {
    let s = line.to_owned()
    if s.contains("时间  [") {
      continue
    }
    for ch in s.to_array() {
      if ch == '[' {
        n = n + 1
      }
    }
  }
  n
}

///|
/// 反向守卫：**真正的**行尾截断仍然要被报出来。
///
/// 构造法：让一根横条的右端明确超出 `TIMELINE_MAX_COLS`。`col_of` 把 `end`
/// 映射到 `scale`（48）为止，所以单靠时间戳撑不到 512；这里改用**超长标签**
/// —— 标签决定 `need`，`need` 决定 `end_col` 能否越过最后一列。
///
/// `Cas(-1000000, 1000000)` 的摘要 `C-1000000>1000000` 长达 18 字符，
/// 堆到行尾时右端必然越过 511。
test "LC-35: 真正的行尾截断仍然如实报出" {
  let ops : Array[Operation] = []
  let mut i = 0
  // 每根 20 列，26 根就能把 512 列用满，再把最后一根挤到越界
  while i < 60 {
    ops.push(Operation::{
      id: i,
      process: 0,
      kind: Cas(-1000000, 1000000),
      result: Bool(true),
      start: i.to_int64(),
      end: i.to_int64(),
    })
    i = i + 1
  }
  let out = render_timeline(History::{ operations: ops, })
  let (undrawn, clipped) = match lc35_counts(out) {
    Some(p) => p
    None => {
      assert_true(false)
      (0, 0)
    }
  }
  // 必须有被钳的横条（否则本测试就没在测它该测的东西）
  assert_true(clipped >= 1)
  assert_eq(lc35_boxes(out) + undrawn, 60)
}
