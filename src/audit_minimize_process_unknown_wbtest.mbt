// minimize_by_process 的 Unknown 镜像回归。
//
// 私有 config helper 与公开入口共用同一实现；公开入口仍固定传默认配置。
// 测试复用 TimeoutRegister：首轮两次 apply 快速，后续 apply 各等待 50ms，
// 在 10ms 预算下确定超时。约五个探针总计 250ms，不再忙等 25 秒。

///|
test "minimize_by_process: 后续 Unknown 不得伪报不存在见证" {
  let h = timeout_pair()
  let config = CheckConfig::{
    time_budget_ms: 10,
    max_states: 200000,
    allow_unknown_results: false,
  }
  let unlimited = CheckConfig::{ ..config, time_budget_ms: 0, }
  assert_true(check_with(h, register_model(), unlimited) is Violation(_))
  let model = TimeoutRegister::{ applications: [0], fast_applications: 2, }
  match minimize_by_process_opt_with_config(h, model, config, MIN_WITNESS) {
    Some(result) => {
      assert_true(result.explanation.contains("检查未能给出结论"))
      assert_true(result.explanation.contains("超过时间预算"))
      assert_true(!result.explanation.contains("没有任何子集"))
    }
    None => fail("后续探针 Unknown 被误报成不存在见证")
  }
}
