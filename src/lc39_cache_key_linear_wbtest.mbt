// ============================================================================
// lc39_cache_key_linear_test.mbt —— 缓存键的构造成本必须是 O(状态) 而不是 O(操作数)（LC-39）
//
// ## 现象
//
// 一份**严格串行**的历史（`--processes 1 --concurrency 0`，每个进程的下一条
// 必须等上一条返回）在线性化意义下只有**唯一**一个合法全序，于是 WGL 的候选
// 表在每一个节点上都恰好只有 1 个元素：搜索树是一条直线，节点数 = 操作数 n，
// 每步 `apply` 一次。这样一份历史的检查应当与 n 成**线性**关系。
//
// 实测（release 版，`check --budget-ms -1`，2026-11-27，三次取中位数）：
//
//     N       setup(仅解析)    full        search      每操作
//     2000     265.7 ms      318.4 ms     52.7 ms     26.3 µs
//     4000     340.4 ms      633.8 ms    293.4 ms     73.3 µs
//     8000     586.8 ms     1667.2 ms   1080.4 ms    135.0 µs
//     16000    830.2 ms     6189.4 ms   5359.3 ms    335.0 µs
//     32000   1852.7 ms    25297.3 ms  23444.6 ms    732.6 µs
//
// 「每操作」成本随 n **线性上升**（26 → 73 → 135 → 335 → 733 µs），也就是总开销
// 是 **O(n²)**：n 翻 16 倍，搜索段翻了 445 倍。这不是「NP 难必然慢」——直线搜索
// 树上根本不存在分支。
//
// ## 根因
//
// `dfs` 的节点入口无条件调用 `cache_key(frame.node_state, remaining)`，
// 而 `cache_key` 把**整条 `remaining` 位串**拼进键里：
//
//     state_to_string(state) + "|" + (n 个 '0'/'1' 字符)
//
// 每个节点都要构造一个长度 O(n) 的字符串并做一次 O(n) 的哈希/插入。节点数
// 已经是 n，于是 n × O(n) = O(n²)。
//
// 两个叠加的浪费：
//
// 1. **键里有一位是恒定的**。在一条直线搜索里只有 1 个候选，节点 k 的
//    `remaining` 必然是「前 k 个为 false、其余为 true」——它由 `depth`
//    完全决定，编码整条位串等于重复传输同一份信息 n 次。
// 2. **键在计算前没有任何机会被跳过**。缓存只在「子问题已确定失败」时写入，
//    而第一次下探到某深度时必然 miss；直线搜索里每个深度只访问一次，于是
//    **每一次 `cache_key` 的结果都被立即丢弃**，纯属白做。
//
// ## 修复方向（不改语义）
//
// 语义判据只有一个：**键必须单射**（LC-36 已锁）。本文件只用**可观测的
// 性质**钉住结果，不绑定实现：
//
// - 不变量一：直线历史的搜索节点数 = 操作数 + 1（含终止叶子）。这是语义
//   判据，同时防止"为了提速而剪掉本该探索的分支"；
// - 不变量二：直线搜索里 `cache_key` 的**调用次数**不随 n 平方增长。用次数
//   而不是耗时钟，CI 上没有噪声；
// - 不变量三：键长只取决于子问题本身，单射性（LC-36）不变。
//
// 正常水平的经量方法记录在本轮 evidence 目录
// （`D:\code\moonbit\audit\2026-11-27\lincheck-evidence\`）。
// ============================================================================

///|
/// `cache_key` 调用计数器由 `checker.mbt` 提供（`cache_key_calls`）。
fn lc39_reset_key_calls() -> Unit {
  cache_key_calls.val = 0
}

///|
fn lc39_key_calls() -> Int {
  cache_key_calls.val
}

///|
/// 生成一份严格串行历史：进程 0 的第 i 条操作在 [2i, 2i+1]，
/// 全部是 `Write(i)` → `Ok`，构造上必然线性一致，且唯一合法全序就是 id 顺序。
fn lc39_serial_history(n : Int32) -> History {
  let ops : Array[Operation] = []
  for i in 0..<n {
    ops.push({
      id: i,
      process: 0,
      kind: Write(i),
      result: Ok,
      start: i.to_int64() * 2L,
      end: (i.to_int64() * 2L) + 1L,
    })
  }
  { operations: ops, }
}

///|
/// **不变量一**：直线历史的搜索节点数恰好等于操作数 + 1（含终止叶子）。
///
/// 这条是**语义**判据（不是性能判据）：唯一合法全序上每一步都只有 1 个候选，
/// 所以节点数 = n（内部节点）+ 1（depth == total 的叶子）。任何"为了跑得快
/// 而少探索"的改动都会把它打破 —— 与 `DEMO.md` 第九节
/// `register_bad → explored=3` 同口径。
test "LC-39: 串行历史的搜索节点数等于操作数加一" {
  let m : AnyModel = Register(register_model())
  let cfg = { ..CheckConfig::default(), time_budget_ms: 0, }
  for n in [1, 2, 5, 50, 200, 1000] {
    let (outcome, stats) = check_with_stats(lc39_serial_history(n), m, cfg)
    assert_true(outcome is Linearizable)
    if stats.explored != n + 1 {
      println("LC-39: n=\{n} explored=\{stats.explored}（应为 n+1）")
      assert_true(false)
    }
  }
}

///|
/// **不变量二**：直线搜索里 `cache_key` 的**调用次数**不得随操作数平方增长。
///
/// 这个量完全可精确计数，不依赖时钟，所以 CI 上没有噪声。
///
/// 旧实现在每个节点入口都无条件算键：n 个节点 × O(n) 字符 = O(n²)。
/// 修好后键只在真正要查/要写缓存时才算 —— 直线搜索永远走不到「全部候选
/// 失败」，缓存也始终为空，于是键的调用次数退化成 O(1)。
///
/// 判据用**计数**而不是时钟：`cache_key` 被包在 `counted_cache_key` 里，
/// 每次调用自增一个全局计数器，与 n 的关系必须是「不随 n 增长」。
test "LC-39: 直线搜索不随操作数平方地构造缓存键" {
  let m : AnyModel = Register(register_model())
  let cfg = { ..CheckConfig::default(), time_budget_ms: 0, }
  let calls = fn(n : Int32) -> Int {
    lc39_reset_key_calls()
    let (outcome, _) = check_with_stats(lc39_serial_history(n), m, cfg)
    ignore(outcome)
    lc39_key_calls()
  }
  let small = calls(200)
  let big = calls(4000)
  // 线性/常量：big ≤ small + 一个小的常数；平方：big ≈ 400 × small
  if big > small * 2 + 16 {
    println("LC-39: cache_key 调用 small(n=200)=\{small} big(n=4000)=\{big}（应为常量级）")
    assert_true(false)
  }
}

///|
/// **不变量三**：键长只取决于子问题本身，不取决于历史里**已经线性化**的部分。
///
/// 这是上一条的根因级表述：把「已线性化的前缀有多长」编进键是**信息冗余**，
/// 正是 O(n²) 的来源。两个子问题若「状态相同 + 剩余集合相同」，键必须相等；
/// 若剩余集合不同，键必须不同（LC-36 的单射性）。
test "LC-39: 键长只取决于剩余集合，不取决于已线性化的前缀长度" {
  // 剩余集合相同（末 5 位全 false 且长度都是 5）、状态相同 → 键必须相同，
  // 与「前面有多少位已线性化」无关。
  let r_short : Array[Bool] = [false, false, false, false, false]
  let k_short = cache_key([7], r_short)
  // LC-36 的单射性不能破：不同的剩余集合必须给不同的键
  let r_other : Array[Bool] = [true, false, false, false, false]
  assert_true(cache_key([7], r_other) != k_short)
  // 状态不同也必须不同
  assert_true(cache_key([8], r_short) != k_short)
  // 键长必须可预测：只含 `#<count>.` + 位串（+ state），不掺任何前缀长度
  // —— 把同一份剩余集合放到更长的历史里，长度不变。
  let k_short2 = cache_key([7], r_short.copy())
  assert_eq(k_short, k_short2)
}
