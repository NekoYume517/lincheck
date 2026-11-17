// ============================================================================
// 最小化探针的 Unknown 三态回归
//
// Unknown 只表示「这次检查没有结论」，既不是 Linearizable，也不是 Violation。
// 可解释性判定与最小化结语都不能把它折叠成一个确定的布尔答案。
// ============================================================================

///|
fn unknown_interval_op() -> Operation {
  Operation::{
    id: 0,
    process: 0,
    kind: Read,
    result: Value(0),
    start: 2L,
    end: 1L,
  }
}

///|
test "minimize unknown: 单操作 Unknown 不得缓存成确定合法" {
  let expl = Expl::new()
  let model = register_model()
  let config = CheckConfig::default()
  let op = unknown_interval_op()
  assert_true(probe_ops([op], model, config) is Unknown(_))
  // 保留既有 Bool API：未知不是「已证明孤立非法」，所以返回 false；
  // 但它也绝不是「已证明合法」，不得写入确定结果缓存。
  assert_true(!expl.is_illegal(op, model, config))
  assert_eq(expl.illegal.length(), 0)
}

///|
test "minimize unknown: 可解释性不得把 Unknown 当成合法单操作" {
  let expl = Expl::new()
  let model = register_model()
  let config = CheckConfig::default()
  let op = unknown_interval_op()
  // 连单操作本身的检查都是 Unknown，就无法证明整个子集满足可解释性。
  assert_true(!explainable([op], model, config, expl))
  assert_eq(expl.illegal.length(), 0)
}

///|
/// 语义与 register 相同，但可精确控制从第 N 次 apply 起变慢。
/// 这样首轮检查确定违规、后续最小化探针确定超时，不依赖机器速度或调度运气。
struct TimeoutRegister {
  applications : Array[Int32]
  fast_applications : Int32
}

///|
pub impl Model for TimeoutRegister with fn name(_self) {
  "timeout-register"
}

///|
pub impl Model for TimeoutRegister with fn init(_self) {
  [0]
}

///|
pub impl Model for TimeoutRegister with fn apply(self, state, kind) {
  self.applications[0] = self.applications[0] + 1
  if self.applications[0] > self.fast_applications {
    let until = @env.now() + 50UL
    while @env.now() < until {

    }
  }
  register_model().apply(state, kind)
}

///|
pub impl Model for TimeoutRegister with fn state_eq(_self, a, b) {
  states_equal(a, b)
}

///|
pub impl Model for TimeoutRegister with fn state_hash(_self, state) {
  poly_hash(state)
}

///|
/// 与 `TimeoutRegister` 同构，但慢档只忙等 **10 ms**（LC-9 用例专用）。
///
/// 为什么另起一个类型而不是改 `TimeoutRegister` 的常量：那两条既有用例
/// （首轮成功 / 删除复验超时）依赖 50 ms 与 10 ms 预算的比例，改常量等于悄悄
/// 改动它们的判据。新用例只想「确定性地让复核超时」，10 ms 足够，
/// 而扫描多个窗口时它把永久测试成本压到 1/5（HANDOVER §21.2-4）。
struct FastTimeoutRegister {
  applications : Array[Int32]
  fast_applications : Int32
}

///|
pub impl Model for FastTimeoutRegister with fn name(_self) {
  "fast-timeout-register"
}

///|
pub impl Model for FastTimeoutRegister with fn init(_self) {
  [0]
}

///|
pub impl Model for FastTimeoutRegister with fn apply(self, state, kind) {
  self.applications[0] = self.applications[0] + 1
  if self.applications[0] > self.fast_applications {
    let until = @env.now() + 10UL
    while @env.now() < until {

    }
  }
  register_model().apply(state, kind)
}

///|
pub impl Model for FastTimeoutRegister with fn state_eq(_self, a, b) {
  states_equal(a, b)
}

///|
pub impl Model for FastTimeoutRegister with fn state_hash(_self, state) {
  poly_hash(state)
}

///|
fn timeout_pair() -> History {
  History::{
    operations: [
      Operation::{
        id: 0,
        process: 0,
        kind: Write(2),
        result: Ok,
        start: 0L,
        end: 10L,
      },
      Operation::{
        id: 1,
        process: 1,
        kind: Read,
        result: Value(0),
        start: 20L,
        end: 30L,
      },
    ],
  }
}

///|
test "minimize unknown: 后续探针超时不得伪报不存在见证" {
  let h = timeout_pair()
  let config = CheckConfig::{
    time_budget_ms: 10,
    max_states: 200000,
    allow_unknown_results: false,
  }
  // 独立 oracle 不限时：这份历史确实违规，不是把合法历史当成最小化对象。
  let unlimited = CheckConfig::{ ..config, time_budget_ms: 0, }
  assert_true(check_with(h, register_model(), unlimited) is Violation(_))
  // 首轮 check 恰好消费两次快速 apply 并得到 Violation；之后所有 probe
  // 都超过 10ms。正确结论是「最小化未完成」，不是「不存在合格见证」。
  let four_state_model = TimeoutRegister::{
    applications: [0],
    fast_applications: 2,
  }
  match minimize_outcome_opt(h, four_state_model, config, MIN_WITNESS) {
    Inconclusive(reason) => assert_true(reason.contains("超过时间预算"))
    _ => fail("后续探针 Unknown 必须保留为 Inconclusive")
  }
  // 旧 Violation 载体也必须如实写「未完成」，不能写「没有任何子集」。
  let model = TimeoutRegister::{ applications: [0], fast_applications: 2, }
  let result = minimize_with(h, model, config)
  assert_true(result.explanation.contains("检查未能给出结论"))
  assert_true(result.explanation.contains("超过时间预算"))
  assert_true(!result.explanation.contains("没有任何子集"))
}

///|
test "minimize unknown: 删除复验 Unknown 不得声称必然变合法" {
  let h = timeout_pair()
  let config = CheckConfig::{
    time_budget_ms: 10,
    max_states: 200000,
    allow_unknown_results: false,
  }
  let unlimited = CheckConfig::{ ..config, time_budget_ms: 0, }
  assert_true(check_with(h, register_model(), unlimited) is Violation(_))
  // 首轮、见证、可解释性和 depth 复核共消耗 8 次快速 apply；随后两次
  // 删除复验都超时。历史与见证均已确定，但「删后必合法」没有证据。
  let model = TimeoutRegister::{ applications: [0], fast_applications: 8, }
  match minimize_outcome_opt(h, model, config, MIN_WITNESS) {
    MinViolation(v) => {
      assert_true(
        probe_ops(remove_chunk(h.operations, 0, 1), model, config) is Unknown(_),
      )
      assert_true(
        probe_ops(remove_chunk(h.operations, 1, 1), model, config) is Unknown(_),
      )
      assert_true(
        !v.explanation.contains(
          "删掉其中任何一个操作，历史都会变回线性一致",
        ),
      )
      assert_true(v.explanation.contains("未知"))
    }
    _ => fail("前 8 次快速 apply 应足以得到确定见证")
  }
}

///|
/// 2026-11-17 审计 LC-8：`NoWitness` 结语的**成因分类**也必须三态。
///
/// `no_explainable_witness_text_for` 的 `reason` 只有两个取值时，
/// 调用方 `cmd_minimize` 把「拿不到成因」的 `Unknown` 折成 `"concurrency-race"`
/// （`main.mbt` 的 NoWitness 分支：`_ => "concurrency-race"`）。于是用户的
/// 历史里如果既没有证据说是竞态、也没有证据说是数据自相矛盾，工具会**编造**
/// 一个成因，把他往错误方向引。这是上一轮「Unknown 不得退化成确定结论」
/// 同一主题的残余（NoWitness 路径）。
///
/// 修法：`reason` 增加第三种取值 `"unknown"`，文案改成如实说明
/// 「成因未定，既不能断言竞态也不能断言自相矛盾」。
///
/// 本用例在修复前会红：`unknown` 落进 `else`，与竞态文本逐字节相同。
test "minimize unknown: NoWitness 结语的成因分类不得把未知折成竞态" {
  let data = no_explainable_witness_text_for(
    3,
    MIN_WITNESS,
    "data-inconsistency",
  )
  let race = no_explainable_witness_text_for(3, MIN_WITNESS, "concurrency-race")
  let unknown = no_explainable_witness_text_for(3, MIN_WITNESS, "unknown")
  // 三条分支必须互不相同（否则「分类」是假的）。
  assert_true(unknown != race)
  assert_true(unknown != data)
  assert_true(data != race)
  // 未知分支不得做出任何一个**具体成因断言**。
  // 判别短语取自两个已知分支各自的断言句：未知分支可以在「既不能断言 A 也
  // 不能断言 B」的否定句里提到这两个词，但不得出现断言句本身。
  assert_true(!unknown.contains("该反例属于并发竞态"))
  assert_true(!unknown.contains("这通常意味着历史数据自相矛盾"))
  assert_true(unknown.contains("成因未能确定"))
  // 已知分支的措辞保持不变（既有 CLI 输出依赖它）。
  assert_true(data.contains("这通常意味着历史数据自相矛盾"))
  assert_true(race.contains("该反例属于并发竞态"))
}

///|
/// `examples/noisy_bad.jsonl` 的 8 个操作（同款硬编码，避免测试依赖文件 IO）。
fn noisy_bad_ops() -> Array[Operation] {
  [
    Operation::{
      id: 0,
      process: 0,
      kind: Read,
      result: Value(0),
      start: 0L,
      end: 2L,
    },
    Operation::{
      id: 1,
      process: 1,
      kind: Write(1),
      result: Ok,
      start: 0L,
      end: 10L,
    },
    Operation::{
      id: 2,
      process: 2,
      kind: Write(2),
      result: Ok,
      start: 12L,
      end: 20L,
    },
    Operation::{
      id: 3,
      process: 3,
      kind: Read,
      result: Value(0),
      start: 22L,
      end: 24L,
    },
    Operation::{
      id: 4,
      process: 1,
      kind: Read,
      result: Value(1),
      start: 30L,
      end: 40L,
    },
    Operation::{
      id: 5,
      process: 2,
      kind: Write(1),
      result: Ok,
      start: 50L,
      end: 60L,
    },
    Operation::{
      id: 6,
      process: 4,
      kind: Read,
      result: Value(1),
      start: 62L,
      end: 70L,
    },
    Operation::{
      id: 7,
      process: 0,
      kind: Read,
      result: Value(0),
      start: 72L,
      end: 80L,
    },
  ]
}

///|
/// 2026-11-17 审计 LC-9：最小化产物的 `Violation.depth` 必须来自**那份见证**的
/// 复核，不得借用另一份历史的 depth。
///
/// 旧实现（`minimize.mbt` 三处）写成：
///
///     let depth = match probe_ops(minimal, model, config) {
///       Violation(v2) => v2.depth
///       _ => v.depth          // ← v 是**原历史**的 Violation
///     }
///
/// `v.depth` 描述的是整份历史的搜索前缀，量纲完全不同：`noisy_bad` 的 check
/// 给出 depth=3 / 见证 4 条，最小化压到 2 条 —— 一旦那次复核没有结论，旧实现
/// 会把「3」贴到一条 2 条操作的见证上（`--json` 的 `depth` 字段、以及
/// `render_violation` 的「最长一致前缀长度」）。与上一轮 LC-D2「A 的证据贴到 B
/// 上」同族。depth 还参与 `violation_reason` 的 data-inconsistency 判据
/// （`depth == 0 && ops.length() == 1`），所以口径错会连带改分类。
///
/// 本用例用可控慢模型扫「第几次 apply 之后变慢」这一小段窗口（`k = 6..10`，
/// 恰好覆盖「见证搜索成功、但 depth 复核超时」那一档），对每一档都要求 depth
/// 不超过见证自身能支撑的范围；窗口上限刻意收窄，避免把慢模型的 50 ms 忙等
/// 变成整个测试套的固定成本（HANDOVER §21.2-4）。
test "minimize unknown: 见证的 depth 不得借用另一份历史" {
  let h = ops_to_history(noisy_bad_ops())
  // 独立 oracle：这份历史确实违规（否则整条用例测的对象就是错的）。
  assert_true(
    check_with(h, register_model(), CheckConfig::default()) is Violation(_),
  )
  let config = CheckConfig::{
    time_budget_ms: 2,
    max_states: 200000,
    allow_unknown_results: false,
  }
  let unlimited = CheckConfig::{ ..config, time_budget_ms: 0, }
  // 原历史那份 check 见证的规模：最小化若压得更小，就是「借用 depth 会露馅」
  // 的那一档（noisy_bad：check 见证 4 条 / depth 3，最小化后 2 条）。
  let check_witness_len = match check_with(h, register_model(), unlimited) {
    Violation(v0) => v0.ops.length()
    _ => 0
  }
  assert_true(check_witness_len > 2)
  let mut saw_shrunk = 0
  let mut k = 0
  while k <= 12 {
    let model = FastTimeoutRegister::{
      applications: [0],
      fast_applications: k,
    }
    match minimize_outcome_opt(h, model, config, MIN_WITNESS) {
      MinViolation(v) =>
        if v.ops.length() > 0 {
          // 见证本身必须真的违规（用不限时的 register 独立复核）。
          assert_true(
            check_with(ops_to_history(v.ops), register_model(), unlimited)
            is Violation(_),
          )
          // 核心断言：depth 描述的是**这条见证**，上限是 len-1。
          // 旧实现回落原历史的 depth（3）贴到 2 条见证上 → 3 > 1，这条会红。
          assert_true(v.depth <= v.ops.length() - 1)
          if v.ops.length() < check_witness_len {
            saw_shrunk = saw_shrunk + 1
          }
        }
      _ => ()
    }
    k = k + 1
  }
  // 防空断言：必须真的走到「最小化把见证压小了」的那些档，
  // 否则上面那条 `depth <= len-1` 会因为见证与原历史一样大而恒真。
  assert_true(saw_shrunk > 0)
}

///|
/// `witness_depth` 的直接契约（确定、便宜）：复核有结论时给那份见证自己的
/// 前缀长度；复核没有结论时如实为 0，绝不借用外部数字。
test "minimize unknown: witness_depth 复核无结论时不声明前缀" {
  let witness : Array[Operation] = [
    Operation::{
      id: 0,
      process: 0,
      kind: Write(2),
      result: Ok,
      start: 12L,
      end: 20L,
    },
    Operation::{
      id: 1,
      process: 3,
      kind: Read,
      result: Value(0),
      start: 22L,
      end: 24L,
    },
  ]
  let config = CheckConfig::{
    time_budget_ms: 1,
    max_states: 200000,
    allow_unknown_results: false,
  }
  // 不限时复核：这份见证确实违规（W=2 之后读到 0），最长一致前缀 1。
  inspect(
    witness_depth(witness, register_model(), CheckConfig::{
      ..config,
      time_budget_ms: 0,
    }),
    content="1",
  )
  // 每次 apply 都慢 50 ms、预算只有 1 ms：复核必然没有结论 → 0。
  let slow = TimeoutRegister::{ applications: [0], fast_applications: 0, }
  inspect(witness_depth(witness, slow, config), content="0")
}
