// ============================================================================
// lc42_cache_off_wbtest.mbt —— `max_states: 0` 必须真的关掉缓存（LC-42 其一）
//
// ## 现象
//
// `CheckConfig.max_states` 的文档契约是「缓存条目上限。`<= 0` 表示**完全关闭**
// 缓存（用于验证缓存不改变语义）」（`checker.mbt` 的字段注释；API.md §3 的
// 「缓存命中时不得改变语义」与 README 的「开/关缓存结果必须一致」都依赖它）。
//
// 旧实现在 `dfs` 里把「缓存没满」写成 `cache.length() < config.max_states`：
//
//     if !ctx.cache_full {
//       if ctx.cache.length() < config.max_states {     // 写入：看上限
//         ctx.cache[write_key] = true
//       } else {
//         ctx.cache_full = true                           // 0 < 0 恒假 → 立即置位
//       }
//     }
//
// `max_states = 0` 时 `0 < 0` 恒为假，**第一个**要写缓存的节点就把
// `cache_full` 置位；`cache` 从头到尾是空的。于是「关缓存」与「上限 1」
// （第一条能存下）在命中行为上是同一档次 —— 而「开/关对照」正是 README
// 列为已声明正确性属性的用法，它依赖的配置恰恰是这里被混淆的那一格。
//
// ## 修的是什么
//
// 写入侧加上 `config.max_states > 0`，「关闭」在入口生效；查询侧不动 ——
// 它只看 `cache` 是否非空，关闭时表恒空，于是「零命中、零条目、零键构造」
// 由同一个不变量同时成立。
//
// ## 判据（全部零噪声：精确计数，不依赖机器速度）
//
// - `max_states <= 0` ⇒ `cache_size = 0`、`cache_hits = 0`、键构造 0 次，
//   且判定与默认配置逐字相同。
// - `max_states = 1` 与 `0` 不同（上限 1 允许一条条目并命中）。
// - 上限生效：条目数不得超过 `max_states`，判定不变。
//
// 那份「缓存密集」历史的规模效应（命中省下的子树要不要一次吃完）是另一个
// 缺陷、另一个提交，见 `lc42_cache_fold_wbtest.mbt`。
// ============================================================================

///|
/// 缓存密集的违规历史：`n` 条全并发同值写 + 一条读到不可能值的读。
///
/// 与 `audit_cache_budget_test.mbt` 同源（它取 `n = 12` 并锁住该形态下
/// 缓存确实承担了大部分工作）。这里取 `n = 6`：关缓存时也只需 1957 个节点，
/// 任何机器上都跑得完。
fn lc42_dense(n : Int32) -> History {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < n {
    ops.push({
      id: i,
      process: i % 3,
      kind: Write(5),
      result: Ok,
      start: 0L,
      end: 100L,
    })
    i = i + 1
  }
  ops.push({
    id: 99,
    process: 9,
    kind: Read,
    result: Value(3),
    start: 200L,
    end: 210L,
  })
  { operations: ops, }
}

///|
fn lc42_cfg(max_states : Int32) -> CheckConfig {
  { time_budget_ms: 0, max_states, allow_unknown_results: false, }
}

///|
fn lc42_verdict(outcome : CheckOutcome) -> String {
  match outcome {
    Linearizable => "Linearizable"
    Violation(_) => "Violation"
    Unknown(_) => "Unknown"
  }
}

///|
/// **判据一**：`max_states <= 0` 真的关掉缓存 —— 零命中、零条目、零键构造，
/// 且判定与默认配置逐字相同。
test "LC-42: max_states <= 0 完全关闭缓存（零命中、零条目、零键构造）" {
  let m = register_model()
  let h = lc42_dense(6)
  let base_verdict = lc42_verdict(check_with_stats(h, m, lc42_cfg(200_000)).0)
  for max_states in [0, -1, -1_000_000] {
    cache_key_calls.val = 0
    let (outcome, stats) = check_with_stats(h, m, lc42_cfg(max_states))
    let keys = cache_key_calls.val
    if stats.cache_size != 0 || stats.cache_hits != 0 || keys != 0 {
      println(
        "LC-42: max_states=\{max_states} 得到 cache_size=\{stats.cache_size} cache_hits=\{stats.cache_hits} key_calls=\{keys}（三者都应为 0）",
      )
      assert_true(false)
    }
    if lc42_verdict(outcome) != base_verdict {
      println(
        "LC-42: max_states=\{max_states} 改写了判定（\{base_verdict} -> \{lc42_verdict(outcome)}）",
      )
      assert_true(false)
    }
  }
}

///|
/// **判据二**：`max_states = 1` 与 `max_states = 0` **不是**同一个配置。
///
/// 上限 1 允许存一条；这条一旦写下，`cache` 就非空、键开始被构造、后续
/// 同键的节点会命中。旧实现把两者混为一谈（都表现为"一条也没写"）。
test "LC-42: max_states = 1 与 0 行为不同（上限 1 允许一条条目）" {
  let h = lc42_dense(6)
  let m = register_model()
  let (outcome1, stats1) = check_with_stats(h, m, lc42_cfg(1))
  if lc42_verdict(outcome1) == "Unknown" {
    println(
      "LC-42: max_states=1 在 n=6 历史上给出 Unknown（不应走到超时）",
    )
    assert_true(false)
  }
  if stats1.cache_size != 1 {
    println(
      "LC-42: max_states=1 的 cache_size=\{stats1.cache_size}（应为 1）",
    )
    assert_true(false)
  }
  if stats1.cache_hits == 0 {
    println("LC-42: max_states=1 一条条目却没有命中")
    assert_true(false)
  }
}

///|
/// **判据三**：上限生效 —— 条目数不得超过 `max_states`，越过上限后判定仍不变。
test "LC-42: 缓存条目数不得超过 max_states 且不改变判定" {
  let h = lc42_dense(6)
  let m = register_model()
  let base_verdict = lc42_verdict(check_with_stats(h, m, lc42_cfg(200_000)).0)
  for k in [1, 2, 7, 100, 4096] {
    let (outcome, stats) = check_with_stats(h, m, lc42_cfg(k))
    if stats.cache_size > k {
      println("LC-42: max_states=\{k} 却有 cache_size=\{stats.cache_size}")
      assert_true(false)
    }
    if lc42_verdict(outcome) != base_verdict {
      println(
        "LC-42: max_states=\{k} 改写了判定（\{base_verdict} -> \{lc42_verdict(outcome)}）",
      )
      assert_true(false)
    }
  }
}
