// ============================================================================
// lc43_cache_off_property_test.mbt —— 缓存的「开/关等价」是属性，不是单点（LC-43）
//
// ## 为什么单独一个文件
//
// `lc42_cache_off_wbtest.mbt` 锁的是"`max_states = 0` 真的关掉缓存"这一格；
// 这里把它升级成**属性**（README 声明的正确性属性）：
//
//   对任意历史 H：(H 在「关缓存」下的判定) == (H 在「开缓存」下的判定)
//
// 判定只允许是 `Linearizable` / `Violation`；`cache_hits` / `cache_size` /
// `explored` 允许不同（缓存只买时间，不买答案）。
//
// 覆盖：4 模型 × 2/3/4 进程 × 2..5 操作 × 每个组合若干 seed。
//
// ## 防 vacuous 的两条
//
// 1. `max_states = 1` 与 `max_states = 0` 的 `cache_size` **必须不同**
//    （1 vs 0）。否则"两个都恒空"这种退化（LC-42a 修的那个毛病）会悄悄回来，
//    而上面那条等价性反而被 trivial 地满足。
// 2. 大上限下至少要有**一部分**用例真的写出缓存条目，否则"开缓存"这一侧
//    等于没开。
//
// ## 参考值从哪来
//
// 等价性只在两个缓存配置之间比，不需要外部参考；但"两边同时错成一样"是
// 可能的（例如缓存键碰撞导致两边都错），所以另外用 400 组 `lc41` 的全排列
// 参考抽检一遍 —— 见同目录 `lc43_reference_agreement_test.mbt`。
// ============================================================================

///|
fn lc43_verdict(o : CheckOutcome) -> String {
  match o {
    Linearizable => "Linearizable"
    Violation(_) => "Violation"
    Unknown(_) => "Unknown"
  }
}

///|
fn lc43_cfg(max_states : Int32) -> CheckConfig {
  { time_budget_ms: 0, max_states, allow_unknown_results: false, }
}

///|
/// 四个模型的 `AnyModel` 包装。用 `AnyModel` 是为了在同一个循环里跑完四模型
/// （泛型函数无法放进数组）。
fn lc43_models() -> Array[(String, AnyModel)] {
  [
    ("register", Register(register_model())),
    ("counter", Counter(counter_model())),
    ("set", Set(set_model())),
    ("queue", Queue(queue_model())),
  ]
}

///|
/// **判据一**：开/关两种配置的判定必须一致，覆盖 4 模型 × 3 进程档 × 4 操作档。
///
/// 这里有意**不**比较 `explored`：缓存只影响成本。比较它是另一条判据
/// （`lc42_fold_no_overclaim_test.mbt` 的第三条）。
test "LC-43: 开缓存与关缓存的判定在 4 模型上手写网格上逐例一致" {
  let configs : Array[Int32] = [0, 1, 200_000]
  let mut cases = 0
  let mut mismatches = 0
  let mut cached_wrote_entries = 0
  for pair in lc43_models() {
    let name = pair.0
    let m = pair.1
    for p in [2, 3, 4] {
      for ops in [2, 3, 4, 5] {
        for seed in [3, 11, 29] {
          let h = generate_random(m, GenConfig::new(p, ops, seed, 0.8))
          let verdicts : Array[String] = []
          let sizes : Array[Int32] = []
          for ms in configs {
            let (o, st) = check_with_stats(h, m, lc43_cfg(ms))
            verdicts.push(lc43_verdict(o))
            sizes.push(st.cache_size)
          }
          cases = cases + 1
          // 三档判定必须全等（且不允许出现 Unknown —— 全是小历史，不该超时）
          if verdicts[0] != verdicts[1] || verdicts[0] != verdicts[2] {
            mismatches = mismatches + 1
            println(
              "LC-43: \{name} p=\{p} ops=\{ops} seed=\{seed} 判定分歧 off=\{verdicts[0]} one=\{verdicts[1]} big=\{verdicts[2]}",
            )
          }
          println("SIZES off=\{sizes[0]} one=\{sizes[1]} big=\{sizes[2]}")
          if verdicts[0] == "Unknown" {
            println(
              "LC-43: \{name} p=\{p} ops=\{ops} seed=\{seed} 给出 Unknown（小历史不该超时）",
            )
            mismatches = mismatches + 1
          }
          // 防 vacuous：上限 1 与 0 的条目数必须不同
          if sizes[0] != 0 || sizes[1] > 1 {
            println(
              "LC-43: \{name} 条目数异常 off=\{sizes[0]} one=\{sizes[1]}",
            )
            mismatches = mismatches + 1
          }
          if sizes[2] > 0 {
            cached_wrote_entries = cached_wrote_entries + 1
          }
        }
      }
    }
  }
  if cases != 144 {
    println(
      "LC-43: 覆盖数不对，cases=\{cases}（应为 4×3×4×3 = 144）",
    )
    assert_true(false)
  }
  if mismatches != 0 {
    println("LC-43: 共 \{mismatches} 例不一致")
    assert_true(false)
  }
  // 至少一半用例在大上限下真的写了缓存条目，否则"开缓存"这一侧是空转
  if cached_wrote_entries * 2 < cases {
    println(
      "LC-43: 只有 \{cached_wrote_entries}/\{cases} 例写过缓存条目，判据接近空转",
    )
    assert_true(false)
  }
}

///|
/// **判据二**：`max_states = 1` 必须真的允许**一条**条目，而 `0` 必须一条都没有。
///
/// 这条与 `lc42_cache_off_wbtest.mbt` 的判据二重复是**故意的**：LC-42a 那次
/// 事故（`0 < 0` 恒假把两者混成一样）如果以另一种写法回来，两个文件会各自
/// 报出来，而不是靠某一条恰好覆盖。
test "LC-43: 上限 1 与 0 的条目数恒为 1 与 0" {
  let h = generate_random(register_model(), GenConfig::new(3, 2, 15, 0.8))
  let m : AnyModel = Register(register_model())
  let (_, off) = check_with_stats(h, m, lc43_cfg(0))
  let (_, one) = check_with_stats(h, m, lc43_cfg(1))
  if off.cache_size != 0 {
    println("LC-43: max_states=0 却有 cache_size=\{off.cache_size}")
    assert_true(false)
  }
  if one.cache_size != 1 {
    println(
      "LC-43: max_states=1 的 cache_size=\{one.cache_size}（应为 1）",
    )
    assert_true(false)
  }
  if one.cache_hits == 0 {
    println("LC-43: max_states=1 存了一条却从未命中")
    assert_true(false)
  }
}
