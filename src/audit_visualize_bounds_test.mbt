// ============================================================================
// 审计回归（2026-11-12）：`order_facts` 的输出必须与见证规模无关
//
// 现象：`visualize` 在大违规历史上直接把 wasm 堆耗尽崩溃——
//
//   $ lincheck gen --model register --processes 4 --ops 2400 --seed 7 --inject > h.jsonl
//   $ lincheck visualize --history h.jsonl        # 退出码 1 之前先打印：
//   RuntimeError: unreachable
//       at tlsf/prepareSize (wasm://wasm/...)
//       at moonbit.malloc_no_grow
//       at @moonbitlang/core/builtin.StringBuilder::grow
//
// 根因：`render_violation` 把见证子集交给 `order_facts`，后者对每对操作判断
// `happens_before` 并各写一行。顺次执行的历史里每一对都成立，于是输出是
// O(k^2) 行：k=7717 时约 5900 万行、单个 StringBuilder 撑爆 wasm 堆。
// 一条「谁来 debug 并发」的诊断命令在输入合法时崩溃，比不输出更糟。
//
// 契约：诊断输出可以有上界，但**必须说明自己截断了**，且上界不能随见证规模增长。
// ============================================================================

///|
/// n 个顺次执行的操作：`i` 的结束早于 `i+1` 的开始，所以任意 `i < j` 都满足
/// `happens_before(op[i], op[j])` —— 这是让成对事实数达到 n*(n-1) 的最短构造。
fn seq_ops(n : Int32) -> Array[Operation] {
  let out : Array[Operation] = []
  let mut i = 0
  while i < n {
    out.push(Operation::{
      id: i,
      process: i % 2,
      kind: Write(i),
      result: Ok,
      start: i.to_int64() * 10L,
      end: i.to_int64() * 10L + 1L,
    })
    i = i + 1
  }
  out
}

///|
test "order_facts output does not grow as the square of the witness" {
  let ops = seq_ops(200)
  let out = order_facts(ops)
  // 200 个顺次操作意味着 39800 对约束。截断是允许的，静默截断不允许。
  assert_true(out.contains("截断"))
  // 上界必须与 39800 行这种数量级无关：给足 20 行事实 + 一行说明的余量。
  assert_true(out.length() < 4000)
}

///|
test "order_facts still reports small witnesses in full" {
  let ops = seq_ops(6)
  let out = order_facts(ops)
  // 6 个顺次操作 = 15 对，完全放得下，不该被截断。
  assert_false(out.contains("截断"))
  assert_true(out.contains("先于"))
}

///|
/// 取 `marker` 之后第一个连续十进制整数；找不到或没有数字返回 -1。
fn int_after_marker(s : String, marker : String) -> Int32 {
  let parts = s.split(marker).collect()
  if parts.length() < 2 {
    return -1
  }
  let tail = parts[1].to_owned()
  let mut i = 0
  let mut acc = 0
  let mut any = false
  let mut going = true
  while i < tail.length() && going {
    let c = tail[i]
    if c >= '0' && c <= '9' {
      acc = acc * 10 + (c.to_int() - '0'.to_int())
      any = true
      i = i + 1
    } else {
      going = false
    }
  }
  if any {
    acc
  } else {
    -1
  }
}

///|
/// 审计回归（2026-11-13）：截断摘要里的数字必须是真的，不能把「被扫描前缀
/// 里的条数」当成「整个见证子集的条数」报出来。
///
/// 现象（`gen --processes 4 --ops 600 --seed 7 --inject` 的 2400 操作历史，
/// 见证子集 507 条操作、507×506 = 256542 对有向组合，真实事实 127745 条）：
///
/// ```text
/// …（输出已截断：已扫描 20000 对操作，共 19137 条时间约束成立，这里只列出前 20 条；…）
/// ```
///
/// 19137 只是**前 20000 对扫描结果**里的命中数（占真值 14.98%），却用「共」
/// 报成整个子集的条数。读者会拿它跟同一段输出里的「见证子集：507 / 600」
/// 对照，从而得到一个差了 6.7 倍的数字——截断可以，截断后改口不行。
///
/// 契约：截断摘要必须分别给出「扫描了多少对 / 扫描范围内成立多少条 /
/// 整个子集实际有多少条」，三个数字都要能被独立核对。
test "order_facts 截断摘要报的是子集真实条数，不是扫描范围内的命中数" {
  let ops = seq_ops(200)
  // 200 个顺次操作：39800 对有向组合里恰好每个无序对只有早的那个方向成立，
  // 因此真实事实数是 19900（= 0+1+2+…+199），而扫描上界只有 20000 对。
  let out = order_facts(ops)
  assert_true(out.contains("截断"))
  let scanned = int_after_marker(out, "已扫描 ")
  let pairs = int_after_marker(out, "个操作共 ")
  let within_scan = int_after_marker(out, "其中 ")
  let actual = int_after_marker(out, "该子集实际共有 ")
  // 扫描对数的上界仍然是 20000
  assert_eq(scanned, 20000)
  // 子集规模 → 有向组合数：200 × 199
  assert_eq(pairs, 39800)
  // 真实事实数：顺次构造下只有「早的先于晚的」这一个方向成立
  assert_eq(actual, 19900)
  // 扫描范围内只可能看到真值的一部分（这正是截断，必须如实区分）
  assert_true(within_scan < actual)
  assert_true(within_scan > 0)
  // 交叉验证：摘要里的条数必须与朴素 O(n²) 逐对计数逐个相等。
  // 顺次构造太规整（每个无序对恰好一条），所以另取一组**区间互相重叠**的操作，
  // 让「并发对数」不为零，这样两套算法的分歧才有机会暴露。
  // 40 条操作 → 1560 对有向组合（未触到 scan_limit），走的是「扫描完整但
  // 只列前 20 条」那条分支，摘要里同样必须报真值。
  let overlapping : Array[Operation] = []
  let mut k = 0
  while k < 40 {
    overlapping.push(Operation::{
      id: k,
      process: k % 3,
      kind: Read,
      result: Value(0),
      start: k.to_int64() * 10L,
      end: k.to_int64() * 10L + 25L,
    })
    k = k + 1
  }
  let mut naive = 0
  for a in overlapping {
    for b in overlapping {
      if a != b && happens_before(a, b) {
        naive = naive + 1
      }
    }
  }
  // 40 条操作、区间宽 25、步长 10：a 先于 b 当且仅当 b >= a+3，
  // 所以 naive = Σ_{a=0..36}(37-a) = 703，是确定算术，不依赖实现。
  assert_eq(naive, 703)
  let out2 = order_facts(overlapping)
  assert_true(out2.contains("截断"))
  assert_eq(int_after_marker(out2, "该子集共 "), naive)
  assert_true(out2.contains("只列出前 20 条"))
}
