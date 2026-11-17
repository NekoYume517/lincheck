// ============================================================================
// LC-10：`order_facts` 截断摘要里「已扫描 N 对」必须是 N 个**去重有序对**
//
// 上一轮 D1 立的规矩是「截断摘要里的三个数字必须各自为真，且能互相核对」：
//
//   …（输出已截断：见证子集 {n} 个操作共 {n*(n-1)} 对有向组合；已扫描 {scanned} 对，
//     其中 {found} 条时间约束成立。…
//
// 三个数字的单位必须一致：`n*(n-1)` 不含自己跟自己，`found` 也只数
// `a != b && a.end < b.start`。但 `scanned` 的递增写在 `a != b` 判定**之外**，
// 把 n 个 `i == j` 的自比较也当成「对」——于是「已扫描 20000 对」实际只覆盖
// 19800 个真正的有序对（n=200 时），而同一句里的「共 39800 对有向组合」是按
// 去重口径算的。两个数于是**无法互相核对**：读者没法用 `scanned` 去重算 `found`。
//
// 判据：按「前 `scanned` 个去重有序对」独立重算事实数，必须与 `其中 N 条` 相等。
// ============================================================================

///|
/// 构造一份能让旧口径露馅的输入：事实集中在第 140 行（行主序）——
/// 前 140 个是「晚」操作、最后两个是「早」操作，于是只有最后两行产生事实。
///
/// n = 142 时 n² = 20164 > 20000 > n(n-1) = 20022，仍然是截断档；而旧口径的
/// 20000 次迭代只覆盖 19859 个去重对，扫描停在**第 140 行的第 120 列**，
/// 新口径会走完整行 140。两者的 `found` 因此不同（120 vs 259），
/// 这正是「同一个数字代表两种东西」的实证。
fn lc10_ops() -> Array[Operation] {
  let out : Array[Operation] = []
  let mut i = 0
  while i < 140 {
    out.push(Operation::{
      id: i,
      process: i % 2,
      kind: Write(1),
      result: Ok,
      start: 1000L,
      end: 1001L,
    })
    i = i + 1
  }
  out.push(Operation::{
    id: 140,
    process: 0,
    kind: Write(1),
    result: Ok,
    start: 0L,
    end: 1L,
  })
  out.push(Operation::{
    id: 141,
    process: 1,
    kind: Write(1),
    result: Ok,
    start: 0L,
    end: 1L,
  })
  out
}

///|
test "LC-10: 截断摘要的「已扫描 N 对」必须是 N 个去重有序对" {
  let ops = lc10_ops()
  let out = order_facts(ops)
  assert_true(out.contains("截断"))
  let scanned = int_after_marker(out, "已扫描 ")
  let pairs = int_after_marker(out, "个操作共 ")
  let within_scan = int_after_marker(out, "其中 ")
  // 三个数字各自的单位先自洽：扫描对数不得超过子集的有向组合总数。
  assert_eq(scanned, 20000)
  assert_eq(pairs, 142 * 141)
  assert_true(scanned <= pairs)
  // 独立重算（不复用实现）：按行主序取前 `scanned` 个「i != j」的有序对，
  // 数出其中成立多少条时间约束。
  let mut expected = 0
  let mut seen = 0
  let mut stop = false
  for a in ops {
    for b in ops {
      if !stop {
        if a != b {
          seen = seen + 1
          if happens_before(a, b) {
            expected = expected + 1
          }
          if seen >= scanned {
            stop = true
          }
        }
      }
    }
  }
  // 这条就是旧口径的证伪点：旧口径的 20000 次迭代只覆盖 19859 个去重对，
  // `found` 与「前 20000 个去重对里的事实数」对不上。
  inspect(within_scan, content=expected.to_string())
}
