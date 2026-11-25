// ============================================================================
// cli37b_json_witness_bounds_wbtest.mbt —— `check --json` 的 witness 数组必须有上界
//
// ## 现象（LC-37 续修）
//
// 上一个提交（4214890）只截了 `explanation` 里的两段文本清单。但 `check --json`
// 根本没有 `explanation` 字段 —— 它的体积全部来自 `witness` 数组：
//
//     $ lincheck check --history h.jsonl --json      # 前 n 条顺次合法写 + 末尾读到不存在值
//     ops=51  → 3540 字节，witness 51 条
//     ops=151 → 10644 字节，witness 151 条
//     ops=401 → 28644 字节，witness 401 条
//
// `witness` 条数**严格等于历史操作数**，每条是一个六字段 JSON 对象
// （`id`/`process`/`op`/`result`/`start`/`end`），放大系数比文本清单还大。
//
// `checker.mbt` 的 `EXPL_PREFIX_MAX_LINES` 文档里曾写「完整数据由
// `check --json` 的 `witness` 数组承载，那里不受此限」—— 这句话等于用一行注释
// 把「输出随输入线性增长」合法化了。JSON 是给程序消费的出口，**更**怕无界：
// 下游 `jq` / 解析器会被一份上亿操作的 witness 直接打死。
//
// ## 修法的两条硬约束
//
// 1. **witness 的正确性契约不能破**：`minimize` / 删除复验要求内存里的见证满足
//    `ops.length() >= min_witness`、可复现、可解释。截断**只发生在序列化到
//    JSON 这一步** —— `Violation.ops` 本身一字不动。
// 2. **不许静默截断**。下游必须能区分「就这么多」与「被砍过」。所以截断时
//    额外输出 `witness_total`（真实条数）与 `witness_truncated`（`true`），
//    未截断时这两个键**不出现** —— 已有四种形状逐字节不变，`json_shape_wbtest`
//    锁着的契约继续成立（`total` 仍是「输入历史的操作数」，与 `witness_total`
//    是两个不同的量，不存在「同一个量两个键名」的问题）。

///|
/// 构造一个含 `n` 条操作的见证（内容不重要，测的是**序列化条数上界**）。
fn js37_witness(n : Int32) -> @lib.Violation {
  let ops : Array[@lib.Operation] = []
  let mut i = 0
  while i < n {
    let t = i.to_int64() * 2L
    ops.push(js_op(i, 0, @lib.Write(i + 1), @lib.Ok, t, t + 1L))
    i = i + 1
  }
  @lib.Violation::{ ops, depth: n, explanation: "", }
}

///|
/// 数串里出现了几次 witness 元素（每个元素恰好一个 `"id":`）。
fn js37_entries(s : String) -> Int32 {
  let mut n = 0
  let mut i = 0
  while i < s.length() {
    if s.length() - i >= 5 && s.substring(start=i, end=i + 5) == "\"id\":" {
      n = n + 1
    }
    i = i + 1
  }
  n
}

///|
/// **核心断言一**：`check --json` 的输出字节数不随见证规模增长。
///
/// 400 / 800 / 1600 三档（都超过上界 200）：无上界时字节数是 4 倍关系，
/// 有上界时必须基本持平。
test "cli37b: check --json 的输出字节数与见证规模脱钩" {
  let a = json_violation(
    js37_witness(400),
    @lib.History::{ operations: [], },
    "non-linearizable",
  )
  let b = json_violation(
    js37_witness(800),
    @lib.History::{ operations: [], },
    "non-linearizable",
  )
  let c = json_violation(
    js37_witness(1600),
    @lib.History::{ operations: [], },
    "non-linearizable",
  )
  // 条数上界生效：三档都只序列化 200 条
  assert_eq(js37_entries(a), @lib.WITNESS_MAX_ENTRIES)
  assert_eq(js37_entries(b), @lib.WITNESS_MAX_ENTRIES)
  assert_eq(js37_entries(c), @lib.WITNESS_MAX_ENTRIES)
  // 字节数的差异只来自两个数字（witness_total）的十进制位数
  let d1 = if b.length() > a.length() {
    b.length() - a.length()
  } else {
    a.length() - b.length()
  }
  let d2 = if c.length() > a.length() {
    c.length() - a.length()
  } else {
    a.length() - c.length()
  }
  assert_true(d1 < 32)
  assert_true(d2 < 32)
}

///|
/// **核心断言二**：截断必须**显式**，且 `witness_total` 如实等于真实条数。
///
/// 这是「静默截断比无界更糟」的落地：下游拿到 `witness` 200 条的同时，
/// 能从 `witness_total = 1600` / `witness_truncated = true` 知道自己看到的不是全部。
test "cli37b: 截断时显式给出 witness_total 与 witness_truncated" {
  let n = 1600
  let s = json_violation(
    js37_witness(n),
    @lib.History::{ operations: [], },
    "non-linearizable",
  )
  assert_true(s.contains("\"witness_truncated\":true"))
  assert_true(s.contains("\"witness_total\":1600"))
  // witness_total 与真正序列化的条数不同 —— 否则「截断」是假的
  assert_true(js37_entries(s) < n)
}

///|
/// **反向守卫**：未超上界时，形状必须**一字不变**（不得凭空多出两个键）。
///
/// `API.md` §7.1 的四种形状由 `json_shape_wbtest.mbt` 逐字节锁住。若无条件加上
/// `witness_total` / `witness_truncated`，那四种形状全部失效、契约被悄悄改掉。
/// 这两个键只在**真的截断**时出现。
test "cli37b: 未截断时不出现 witness_total / witness_truncated" {
  let s = json_violation(
    js37_witness(3),
    @lib.History::{ operations: [], },
    "non-linearizable",
  )
  assert_false(s.contains("witness_total"))
  assert_false(s.contains("witness_truncated"))
  assert_eq(js37_entries(s), 3)
  // 恰好等于上界时也不截断
  let exact = json_violation(
    js37_witness(@lib.WITNESS_MAX_ENTRIES),
    @lib.History::{ operations: [], },
    "non-linearizable",
  )
  assert_eq(js37_entries(exact), @lib.WITNESS_MAX_ENTRIES)
  assert_false(exact.contains("witness_truncated"))
}

///|
/// **契约不破**：内存里的 `Violation.ops` 保持完整，截断只发生在序列化。
///
/// `minimize` 的删除复验、`witness_ok` 的复现检查都读 `ops` 本身。若为了实现
/// 上界而把 `ops` 砍掉，这两处会静默失效 —— 那才是真正的正确性破坏。
test "cli37b: 序列化截断不得改动内存里的见证" {
  let n = 1600
  let v = js37_witness(n)
  assert_eq(v.ops.length(), n)
  let _ = json_violation(
    v,
    @lib.History::{ operations: [], },
    "non-linearizable",
  )
  // 序列化之后仍然是 1600 条
  assert_eq(v.ops.length(), n)
}
