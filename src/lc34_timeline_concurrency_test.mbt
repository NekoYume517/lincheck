// ============================================================================
// lc34_timeline_concurrency_test.mbt —— 时间轴不得把**并发**画成**先后**
//
// ## 现象
//
// `visualize` 是 `check` 结论的视觉证据。它必须保住的方向性性质是：
//
//     图上一个横条整体在另一个的**左边**  ⇒  前者 happens-before 后者
//
// 旧实现（`layout_row` 的游标 `start_col = max(want_start, cursor)`）把同一
// 进程的横条强行一根接一根排开，游标因此盖过了真实时间戳：
//
//     proc 0  |[W=5                                            ] [R->5]
//             +----------------------------------------------------------> 时间  [0..1000]
//
// 两条操作的区间分别是 `[0,1000]` 与 `[400,600]`——后者整个落在前者内部，
// `happens_before` 两个方向都为假。`check` 也确实把它们当并发：同一条 Read
// 写成 `R->5` 判 Linearizable、写成 `R->0` 同样判 Linearizable，说明这个顺序
// 没有被钉死。图却画成「W 先完成，然后 R 才开始」——读出的顺序约束是伪造的。
//
// ## 根因
//
// `layout_row`：`start_col = if want_start > cursor { want_start } else { cursor }`。
// `want_start` 由时间戳算出（正确），`cursor = 上一根横条的 end_col + 2`（与时间
// 无关）。当上一条还没结束、下一条就开始了（正好是并发），`cursor` 赢，真实
// 时间戳被丢弃，横向位置不再由时间决定。
//
// 文件头那句自我声明也写错了：「同一进程内的操作保证按时间顺序排开、互不覆盖」。
// 前半句成立（`compare_ops` 按 start 排序），后半句不成立：并发定义只看时间区间
// （`history.mbt` 的 `happens_before`），与进程号无关；同一进程的重叠区间是被
// `check` 当作并发的正经输入，不是非法输入。

///|
/// 画布行的标签列宽度（`|` 之前的字符数）。
fn lc34_label_width(line : String) -> Int32 {
  let mut c = 0
  for ch in line.to_array() {
    if ch == '|' {
      return c
    }
    c = c + 1
  }
  0
}

///|
/// 把内容串切成若干 `(left, right)` 横条区间（列号相对内容起点）。
fn lc34_boxes(content : String) -> Array[(Int32, Int32)] {
  let boxes : Array[(Int32, Int32)] = []
  let mut open = -1
  let mut c = 0
  for ch in content.to_array() {
    if ch == '[' {
      open = c
    } else if ch == ']' {
      if open >= 0 {
        boxes.push((open, c))
      }
      open = -1
    }
    c = c + 1
  }
  boxes
}

///|
/// `render_timeline` 输出里的所有画布内容行（去掉标签行与轴行）。
fn lc34_canvas(out : String) -> Array[String] {
  let rows : Array[String] = []
  for line in out.split("\n").collect() {
    let s = line.to_owned()
    let w = lc34_label_width(s)
    if w > 0 {
      rows.push(s.substring(start=w + 1))
    }
  }
  rows
}

///|
/// **核心不变量**：图上「分离」的那一对，其左右位置必须由时间戳支撑。
///
/// 用最干净的退化情形测：同进程、区间完全包含（`[0,1000]` 与 `[400,600]`）。
/// 这两条完全并发，横向位置却由时间戳决定 —— 二者时间上必然重叠，所以修复后
/// 它们**不能**画成横向分离（分离就等于断言「前者先完成」）。
///
/// 旧实现把这对并发操作塞进同一行且横向分离，本测试红。
test "LC-34: 同进程并发的操作不得画成一前一后" {
  let h = History::{
    operations: [
      Operation::{
        id: 0,
        process: 0,
        kind: Write(5),
        result: Ok,
        start: 0L,
        end: 1000L,
      },
      Operation::{
        id: 1,
        process: 0,
        kind: Read,
        result: Value(5),
        start: 400L,
        end: 600L,
      },
    ],
  }
  // 前提一：二者完全并发（`check` 的口径）
  assert_false(happens_before(h.operations[0], h.operations[1]))
  assert_false(happens_before(h.operations[1], h.operations[0]))
  // 前提二：顺序真的没被钉死 —— 换成「读到 0」仍然 Linearizable
  let flipped = History::{
    operations: [
      h.operations[0],
      Operation::{
        id: 1,
        process: 0,
        kind: Read,
        result: Value(0),
        start: 400L,
        end: 600L,
      },
    ],
  }
  assert_true(
    match
      check(
        flipped,
        AnyModel::Register(register_model()),
        CheckConfig::default(),
      ) {
      Linearizable => true
      _ => false
    },
  )
  // 判定一：两根横条都必须真实画出来（不能靠「丢一根」蒙混过关）
  let rows = lc34_canvas(render_timeline(h))
  assert_true(rows.length() > 0)
  let mut total_boxes = 0
  for row in rows {
    total_boxes = total_boxes + lc34_boxes(row).length()
  }
  assert_eq(total_boxes, 2)
  // 判定二：并发的一对**不得**画在同一条画布行上。
  //
  // 同一行内的两根横条，读者只能从左右位置理解顺序；而并发没有顺序，画成
  // 左右并列就是伪造约束（旧实现正是如此）。修复后它们必须纵向叠在不同行。
  for row in rows {
    assert_true(lc34_boxes(row).length() <= 1)
  }
  // 判定三：两根横条在水平方向**确实有重叠**（不是被推到一前一后）。
  //
  // 挑出每行第一根横条的左端列号：并发区间 [0,1000] 与 [400,600] 映射到
  // 列 0 与 col_of(400)，后者必须落在前者跨度之内 —— 也就是左端差距严格
  // 小于前者的宽度。
  let lefts : Array[(Int32, Int32)] = []
  for row in rows {
    let boxes = lc34_boxes(row)
    if boxes.length() == 1 {
      lefts.push(boxes[0])
    }
  }
  assert_eq(lefts.length(), 2)
  let widths = (lefts[0].1 - lefts[0].0, lefts[1].1 - lefts[1].0)
  let total_w = if widths.0 > widths.1 { widths.0 } else { widths.1 }
  let gap = if lefts[0].0 > lefts[1].0 {
    lefts[0].0 - lefts[1].0
  } else {
    lefts[1].0 - lefts[0].0
  }
  // 左端间距必须小于较长那根的宽度 —— 即两者横向真的重叠
  assert_true(gap < total_w)
}

///|
/// 反向断言：**不重叠**的同进程操作必须仍然横向分离（先后顺序看得见）。
///
/// 这条防的是「为了修 LC-34 把重叠和串行一律叠起来」——那会让串行历史也失去
/// 可读性，等于把 `visualize` 变成废物。
test "LC-34: 串行的同进程操作仍然横向分离" {
  let h = History::{
    operations: [
      Operation::{
        id: 0,
        process: 0,
        kind: Write(1),
        result: Ok,
        start: 0L,
        end: 10L,
      },
      Operation::{
        id: 1,
        process: 0,
        kind: Write(2),
        result: Ok,
        start: 20L,
        end: 30L,
      },
      Operation::{
        id: 2,
        process: 0,
        kind: Read,
        result: Value(2),
        start: 40L,
        end: 50L,
      },
    ],
  }
  assert_true(happens_before(h.operations[0], h.operations[1]))
  assert_true(happens_before(h.operations[1], h.operations[2]))
  let rows = lc34_canvas(render_timeline(h))
  let mut total = 0
  let mut max_on_row = 0
  for row in rows {
    let n = lc34_boxes(row).length()
    total = total + n
    if n > max_on_row {
      max_on_row = n
    }
  }
  assert_eq(total, 3)
  // 三条全部在同一行，且横向依次分离
  assert_eq(max_on_row, 3)
}
