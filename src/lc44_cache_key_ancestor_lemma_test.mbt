// ============================================================================
// lc44_cache_key_ancestor_lemma_test.mbt —— 把「祖先链上键必不相同」钉成引理
//
// ## 引理
//
// 设 `dfs` 的缓存键为 `key(node) = (node_state, remaining)`，
// `anc` 是 `desc` 的**真祖先**（沿 `stack[i].via` 上溯可达）。则
//
//     key(anc) ≠ key(desc)
//
// **证明**：`desc` 由 `anc` 出发、每下探一层消费恰好一个操作，
// 所以 `remaining(desc) = remaining(anc) \ {被消费的那些}`。真祖先意味着至少
// 消费了一个（`remaining` 只减不增，且 `desc.depth > anc.depth`），于是
// `remaining(desc) ⊊ remaining(anc)` —— 两者不相等。而键把 `remaining` 的位串
// **整体**编进去（`bits_full` 逐位编码、非首尾省略），集合不同 ⇒ 位串不同 ⇒
// 键不同。若 `remaining` 相同，则必然 `desc.depth == anc.depth`，即同一节点。
//
// ## 这条引理的后果
//
// `checker.mbt` 命中分支里的「折叠到最近一个已判死的祖先」在**任何**搜索形态下
// 都只能折到 `closest_hit == top`（即命中节点自己），也就是与"只弹一层"等价。
// 第二十一轮在 4 种构造（全写 / 深叶失败 / 带读 / 不同并发度）上实测折叠深度
// **100% 为 0**，与本引理一致。
//
// 该结论把 LC-42b 从「P2 性能缺陷」降级为「P4 结构性改进（当前形态不可观测）」：
// 折叠代码存在的价值是"若将来出现 `remaining` 在祖先链上保持不变的搜索形态，
// 它已经是对的"，而**这条测试会先红**告诉下一个人"引理不再成立"。
//
// ## 为什么要有一条"永远绿"的测试
//
// 「不可能」如果只写在注释里，下一个人改搜索算法时不会有人提醒他。这条测试把
// 它变成**被持续监视的不可能**：一旦有人引入"祖先与后代共享同一 `remaining`"
// 的形态（例如允许空操作、或改成按时间戳而非消费操作推进），引理失效，
// 折叠的语义假设就要重新论证 —— 测试先叫住他。
// ============================================================================

///|
/// 四种形态的历史生成器，覆盖「缓存密集 / 深叶失败 / 全写 / 乱序并发」。
fn lc44_shapes() -> Array[History] {
  let shapes : Array[History] = []

  // 形态 1：n 条全并发同值写 + 一条假读（缓存密集，最容易被命中）
  for n in [4, 6, 9] {
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
    shapes.push({ operations: ops, })
  }

  // 形态 2：k 轮「两个并发写 + 一个读到错误值」（深叶失败）
  for k in [3, 5] {
    let ops : Array[Operation] = []
    let mut id = 0
    let mut t : Int64 = 0L
    for i in 0..<k {
      ops.push({
        id,
        process: 0,
        kind: Write(i),
        result: Ok,
        start: t,
        end: t + 10L,
      })
      id = id + 1
      ops.push({
        id,
        process: 1,
        kind: Write(100 + i),
        result: Ok,
        start: t + 1L,
        end: t + 11L,
      })
      id = id + 1
      ops.push({
        id,
        process: 2,
        kind: Read,
        result: Value(999),
        start: t + 12L,
        end: t + 13L,
      })
      id = id + 1
      t = t + 13L
    }
    shapes.push({ operations: ops, })
  }

  // 形态 3：全部是写（每条交错都合法，成功即返回，几乎不回溯）
  let ops3 : Array[Operation] = []
  for i in 0..<6 {
    ops3.push({
      id: i,
      process: i % 2,
      kind: Write(i),
      result: Ok,
      start: i.to_int64() * 4L,
      end: i.to_int64() * 4L + 5L,
    })
  }
  shapes.push({ operations: ops3, })

  // 形态 4：随机并发生成（含 Cas/Read 混合），固定 seed 可复现
  for seed in [7, 23] {
    shapes.push(
      generate_random(register_model(), GenConfig::new(3, 3, seed, 0.8)),
    )
  }

  shapes
}

///|
fn lc44_cfg() -> CheckConfig {
  { time_budget_ms: 0, max_states: 200_000, allow_unknown_results: false, }
}

///|
/// **判据一（主引理）**：任意一次命中，`closest_hit` 必然就是 `top` 自己 ——
/// 即折叠深度恒为 0，缓存键在祖先链上互不相同。
///
/// 用 `max_fold_depth` 这个**可观测的全局上界**断言：它由 `checker.mbt` 的命中
/// 分支记录（每次折行时把 `top - closest_hit` 的最大值累积），所以这不是
/// "测代码内部变量"，而是"测一份被暴露出来的关键量"。任何让引理失效的改动
/// 都会让它变大。
test "LC-44: 缓存键在祖先链上必不相同（折叠深度恒为 0）" {
  let m : AnyModel = Register(register_model())
  let shapes = lc44_shapes()
  let mut hits_total = 0
  for i, h in shapes {
    max_fold_depth_reset()
    let (outcome, stats) = check_with_stats(h, m, lc44_cfg())
    let depth = max_fold_depth()
    // 每个形态都允许是线性一致或违规，但不允许 Unknown（都是小历史）
    if outcome is Unknown(_) {
      println(
        "LC-44: 形态 \{i}（n=\{h.operations.length()}）给出 Unknown，判据不成立",
      )
      assert_true(false)
    }
    if depth != 0 {
      println(
        "LC-44: 形态 \{i}（n=\{h.operations.length()}）折叠深度=\{depth}（引理失效：祖先与后代共享了缓存键）",
      )
      assert_true(false)
    }
    hits_total = hits_total + stats.cache_hits
  }
  // 防 vacuous：这批形态必须真的**发生过命中**，否则本条判据空转
  if hits_total == 0 {
    println("LC-44: 所有形态一次命中都没有，判据空转")
    assert_true(false)
  }
}

///|
/// **判据二（引理的直接推论）**：把折叠换成"就地判死"（`return false`）会
/// **改变判定**吗？
///
/// 引理成立 ⇒ 折叠本来就只折到节点自己 ⇒ "折到 top"与"就地判死"在当前实现里
/// 是**不同的**（前者要把节点弹栈、恢复 `remaining`/`path` 让上层继续试兄弟，
/// 后者直接把它们丢掉）。这条测试不测那个差异，只钉住一个**下界事实**：
/// 上面那批形态里命中确实发生在"已展开"的节点上（`hits > 0` 且 `explored >
/// cache_size`），所以判据一不是靠"根本没命中"过掉的。
test "LC-44: 命中确实发生在已展开节点上（判据一非空转的下界）" {
  let m : AnyModel = Register(register_model())
  let h = generate_random(register_model(), GenConfig::new(3, 3, 15, 0.8))
  let (outcome, stats) = check_with_stats(h, m, lc44_cfg())
  if outcome is Unknown(_) {
    println("LC-44: seed=15 给出 Unknown")
    assert_true(false)
  }
  if stats.cache_hits == 0 {
    println("LC-44: seed=15 一次命中都没有")
    assert_true(false)
  }
  if stats.explored < stats.cache_size {
    println(
      "LC-44: explored=\{stats.explored} < cache_size=\{stats.cache_size}（形态异常）",
    )
    assert_true(false)
  }
}
