///|
/// 回归：**大而合法的历史不得让进程崩掉**（栈溢出 P0，2026-11-04 审计）。
///
/// ## 缺陷形态（修复前）
///
/// `dfs` 是递归实现，递归深度等于已线性化操作数。合法历史**必须**走到
/// `depth == total`，所以深度就等于历史操作总数。实测四个模型
/// （register/counter/set/queue）在约 2500 操作处全部以
/// `STATUS_STACK_OVERFLOW`（`0xC00000FD`，退出码 -1073741571）死掉，
/// 界面上只剩一行 `thread 'main' has overflowed its stack`。
///
/// 危害有三层，都不是「慢」而是「错」：
///
/// 1. **契约外第六态**。文档声明的退出码只有 0/1/2/3/4，段错误不在此列。
/// 2. **「超时返回 Unknown 不猜」在默认配置下不可达**。`CheckConfig::default()`
///    是 5000ms，而崩溃发生在这个预算用尽之前；只有把预算压到 100ms 才会
///    先超时返回（侥幸，不是修复）。
/// 3. **申报书与 PLAN 自相矛盾**：申报书声称「20 万条上限，超限返回 Unknown」，
///    `PLAN.md` 声称「没有 history 条数上限」，而实测 3000 条即崩。
///
/// ## 本测试锁定什么
///
/// - 6000 操作的**合法**历史必须给出 `Linearizable`，既不能崩，也不能
///   退化成 `Unknown`（修复前的 2400 操作历史是能给出结论的，修复后
///   不能反而变差）
/// - 同一份历史在 1ms 预算下必须走「超时 → Unknown」路径，证明该契约
///   在修复后真的可达
test "checker: 6000-op legal history does not crash the process" {
  let cfg = GenConfig::new(4, 1500, 7, 0.5)
  let h = generate_consistent(register_model(), cfg)
  inspect(h.operations.length(), content="6000")
  // 默认预算：必须给出确定结论
  match check(h, AnyModel::Register(register_model()), CheckConfig::default()) {
    Linearizable => ()
    Violation(_) => abort("legal history reported as violation")
    Unknown(reason) =>
      abort("legal 6000-op history degenerated to Unknown: \{reason}")
  }
  // 极小预算：必须走超时路径而不是崩
  let tight = CheckConfig::{
    time_budget_ms: 1,
    max_states: 200_000,
    allow_unknown_results: false,
  }
  match check(h, AnyModel::Register(register_model()), tight) {
    Unknown(_) => ()
    Linearizable => abort("1ms budget finished 6000 ops; budget not honoured")
    Violation(_) => abort("legal history reported as violation")
  }
}

///|
/// 回归：**每个模型都能承受自身规模的大历史**，不只 register。
///
/// 修复前四个模型一起崩（崩溃点与模型无关，只与操作数有关，因为每帧都
/// 携带一份 `State` 拷贝）。这条测试防止「只测 register 就收工」——
/// set/queue 的 State 更长，理论上更早打穿栈。
test "checker: all four models handle 4000-op legal histories" {
  let cfg = GenConfig::new(4, 1000, 11, 0.5)
  // register
  let h_reg = generate_consistent(register_model(), cfg)
  inspect(h_reg.operations.length(), content="4000")
  match
    check(h_reg, AnyModel::Register(register_model()), CheckConfig::default()) {
    Linearizable => ()
    Violation(_) => abort("register: legal history reported as violation")
    Unknown(r) => abort("register: legal history degenerated to Unknown: \{r}")
  }
  // counter
  let h_ctr = generate_consistent(counter_model(), cfg)
  match
    check(h_ctr, AnyModel::Counter(counter_model()), CheckConfig::default()) {
    Linearizable => ()
    Violation(_) => abort("counter: legal history reported as violation")
    Unknown(r) => abort("counter: legal history degenerated to Unknown: \{r}")
  }
  // set
  let h_set = generate_consistent(set_model(), cfg)
  match check(h_set, AnyModel::Set(set_model()), CheckConfig::default()) {
    Linearizable => ()
    Violation(_) => abort("set: legal history reported as violation")
    Unknown(r) => abort("set: legal history degenerated to Unknown: \{r}")
  }
  // queue
  let h_q = generate_consistent(queue_model(), cfg)
  match check(h_q, AnyModel::Queue(queue_model()), CheckConfig::default()) {
    Linearizable => ()
    Violation(_) => abort("queue: legal history reported as violation")
    Unknown(r) => abort("queue: legal history degenerated to Unknown: \{r}")
  }
}

///|
/// 回归：**超预算的判定文本带预算数字**（CLI 映射退出码 3 的依据）。
///
/// 迭代改写最怕把「超时」写成「崩掉」或「判成一致」。这条测试用必然超
/// 预算的规模，断言结论是 `Unknown` 且原因文本里出现预算数字。
test "checker: exhausted budget yields Unknown naming the budget" {
  let cfg = GenConfig::new(8, 500, 3, 0.5)
  let h = generate_consistent(register_model(), cfg)
  inspect(h.operations.length(), content="4000")
  let tight = CheckConfig::{
    time_budget_ms: 1,
    max_states: 200_000,
    allow_unknown_results: false,
  }
  match check(h, AnyModel::Register(register_model()), tight) {
    Unknown(reason) =>
      assert_true(reason.contains("预算") || reason.contains("budget"))
    Linearizable => abort("1ms budget should not finish 4000 ops")
    Violation(_) => abort("legal history reported as violation")
  }
}
