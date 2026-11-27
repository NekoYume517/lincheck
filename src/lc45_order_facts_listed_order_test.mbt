// ============================================================================
// LC-45 —— `order_facts` 完整扫描（分支 B）列出的每条约束必须**真的成立**
//
// ## 现象（反向探测时发现）
//
// `render_violation` 先把见证子集按 id 排序（`sort_ops_by_id`）再交给
// `order_facts`。函数体第一行却是 `let mut found = 0` —— 它接受的是任意顺序
// 的输入，自己**从未排序**：
//
// - 截断分支（分支 A，`scanned >= scan_limit`）：只数对、只写前缀，不打时间戳，
//   所以问题不可观测；
// - 完整扫描分支（分支 B，`found > shown`）：却把 `a.end < b.start` 逐条打进
//   「时间约束（这些顺序无法调换）」——横向投影的 `>start` 才是 A 的 `end`。
//
// ## 为什么这是真缺陷而不是措辞问题
//
// 这段输出在 `check` 里直接挂在结论下面（`cmd_check` → `render_violation`），
// 「时间约束」是读者据以重放见证的顺序证据。顺序一旦是「按 id」而不是
// 「按时间」，读者手上只有一份**未排序**的历史输入（JSONL 是按文件行序读的，
// `History.add` 不排序），和一段声称存在 `end < start` 的清单，两者对不上。
//
// 既有的 `order_facts` 测试全部喂**内部已按 start 升序**的数组
// （`seq_ops` / `lc10_ops` / `overlapping`），所以旧的全排列实现从来没被
// 真正的输入次序考验过。
//
// ## 判据（双向）
//
// 1. 正向：每条 `先于` 行里的两个时间戳必须真的满足 `早 < 晚`；
// 2. 反向：列出的这 20 条必须与「按时间排好序之后」的前 20 条逐条相同
//    —— 只满足第 1 条还不够（随便挑 20 条真事实也能过），必须与**唯一**的
//    时间顺序一致；
// 3. 归档：输入被就地重排（副作用）同样不允许 —— 调用方传进来的见证子集
//    还要用来渲染时间轴，静默换序会让两处输出互相矛盾。
// ============================================================================

///|
/// 一组**故意打乱**的操作：时间次序 = `[3,1,4,0,2]`。
/// 6 个操作 → 15 条约束（> fact_limit 的 20？不，15 < 20，走「完整扫描 +
/// 全列出」那条路；见下面的第二组用 8 个操作制造截断）。
fn lc45_shuffled_ops() -> Array[Operation] {
  [
    Operation::{
      id: 0,
      process: 0,
      kind: Read,
      result: Value(1),
      start: 30L,
      end: 31L,
    },
    Operation::{
      id: 1,
      process: 1,
      kind: Read,
      result: Value(1),
      start: 10L,
      end: 11L,
    },
    Operation::{
      id: 2,
      process: 0,
      kind: Read,
      result: Value(1),
      start: 40L,
      end: 41L,
    },
    Operation::{
      id: 3,
      process: 1,
      kind: Read,
      result: Value(1),
      start: 0L,
      end: 1L,
    },
    Operation::{
      id: 4,
      process: 2,
      kind: Read,
      result: Value(1),
      start: 20L,
      end: 21L,
    },
  ]
}

///|
/// 把十进制串解析成 `Int64`；不合法返回 `None`。
///
/// 本包不依赖 `moonbitlang/core/strconv`，所以手写：`-` 开头为负，
/// 其余必须全是 ASCII 数字，且长度不得为 0。
fn lc45_parse_dec(s : String) -> Int64? {
  let cs = s.to_array()
  if cs.length() == 0 {
    return None
  }
  let mut neg = false
  let mut i = 0
  if cs[0] == '-' {
    neg = true
    i = 1
    if cs.length() == 1 {
      return None
    }
  }
  let mut acc = 0L
  while i < cs.length() {
    let c = cs[i]
    if c < '0' || c > '9' {
      return None
    }
    acc = acc * 10L + (c.to_int() - '0'.to_int()).to_int64()
    i = i + 1
  }
  Some(if neg { -acc } else { acc })
}

///|
/// 从 `先于` 行里抽出 `(早, 晚)` 两个时间戳。
///
/// 形如：`    · R(proc 0) 先于 R(proc 1)：0 < 10`
fn lc45_parse_pair(line : String) -> (Int64, Int64)? {
  let parts = line.split("：").collect()
  if parts.length() < 2 {
    return None
  }
  let tail = parts[1].to_owned().trim().to_owned()
  let halves = tail.split(" < ").collect()
  if halves.length() < 2 {
    return None
  }
  let a = lc45_parse_dec(halves[0].to_owned())
  let b = lc45_parse_dec(halves[1].to_owned())
  match (a, b) {
    (Some(x), Some(y)) => Some((x, y))
    _ => None
  }
}

///|
test "LC-45: 完整扫描分支列出的每条时间约束都真的成立（input 未排序）" {
  let ops = lc45_shuffled_ops()
  let out = order_facts(ops)
  // 5 个操作 → 10 条约束，全部列出（fact_limit = 20，不触发截断说明）
  assert_false(out.contains("截断"))
  let lines = out.split("\n").collect()
  let mut checked = 0
  for line in lines {
    let l = line.to_owned()
    if l.contains("先于") {
      match lc45_parse_pair(l) {
        Some((early, late)) => {
          // 判据 1：这条约束必须真的成立
          if !(early < late) {
            println("LC-45: 输出了一条不成立的约束：\{l}")
            assert_true(false)
          }
          checked = checked + 1
        }
        None => {
          println("LC-45: 无法解析的约束行：\{l}")
          assert_true(false)
        }
      }
    }
  }
  assert_eq(checked, 10)
  // 全部 10 条 + 20 条上限：这里正好把唯一的时间顺序完整列出
  let sorted = ops.copy()
  sorted.sort_by(compare_ops)
  let expected_pairs : Array[String] = []
  for a in sorted {
    for b in sorted {
      if a != b && a.end < b.start {
        expected_pairs.push("\{a.end} < \{b.start}")
      }
    }
  }
  assert_eq(expected_pairs.length(), 10)
  for pair in expected_pairs {
    if !out.contains(pair) {
      println("LC-45: 缺了按时间顺序应出现的约束 \{pair}")
      assert_true(false)
    }
  }
}

///|
test "LC-45: 8 个乱序操作走截断分支，列出的 20 条仍是时间序的前 20 条" {
  // 8 个顺次操作但**倒序**塞进数组：28 条约束 > fact_limit(20)，走截断分支 B。
  let ops : Array[Operation] = []
  let mut i = 7
  while i >= 0 {
    ops.push(Operation::{
      id: i,
      process: i % 2,
      kind: Write(i),
      result: Ok,
      start: i.to_int64() * 10L,
      end: i.to_int64() * 10L + 1L,
    })
    i = i - 1
  }
  let out = order_facts(ops)
  assert_true(out.contains("截断"))
  let lines = out.split("\n").collect()
  let listed : Array[String] = []
  for line in lines {
    let l = line.to_owned()
    if l.contains("先于") {
      match lc45_parse_pair(l) {
        Some((early, late)) =>
          if !(early < late) {
            println("LC-45: 截断分支列出不成立的约束：\{l}")
            assert_true(false)
          }
        None => assert_true(false)
      }
      listed.push(l)
    }
  }
  assert_eq(listed.length(), 20)
  // 唯一的「按时间序的前 20 条」必须被逐条命中
  let sorted = ops.copy()
  sorted.sort_by(compare_ops)
  let expected : Array[String] = []
  for a in sorted {
    for b in sorted {
      if a != b && a.end < b.start && expected.length() < 20 {
        expected.push("\{a.end} < \{b.start}")
      }
    }
  }
  assert_eq(expected.length(), 20)
  for k, pair in expected {
    if !listed[k].contains(pair) {
      println("LC-45: 第 \{k} 条应为 \{pair}，实为 \{listed[k]}")
      assert_true(false)
    }
  }
}

///|
test "LC-45: order_facts 不得就地重排调用方的数组" {
  let ops = lc45_shuffled_ops()
  let before : Array[Int32] = []
  for op in ops {
    before.push(op.id)
  }
  let _ = order_facts(ops)
  let after : Array[Int32] = []
  for op in ops {
    after.push(op.id)
  }
  assert_eq(after.length(), before.length())
  for i in 0..<before.length() {
    if before[i] != after[i] {
      println(
        "LC-45: 调用方数组被就地改序 —— 位置 \{i} 由 \{before[i]} 变成 \{after[i]}",
      )
      assert_true(false)
    }
  }
}
