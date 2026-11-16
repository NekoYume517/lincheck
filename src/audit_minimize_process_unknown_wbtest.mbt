// minimize_by_process 的 Unknown 镜像回归。
//
// 该公开入口固定使用默认 5000ms 预算。模型只在首轮两次 apply 保持快速，
// 后续 apply 等待 5100ms，因而约五个后续探针各超时一次；测试约 25 秒，
// 换来不依赖机器速度的「首轮 Violation、后续全部 Unknown」确定性。

///|
struct ProcessTimeoutRegister {
  applications : Array[Int32]
}

///|
pub impl Model for ProcessTimeoutRegister with fn name(_self) {
  "process-timeout-register"
}

///|
pub impl Model for ProcessTimeoutRegister with fn init(_self) {
  [0]
}

///|
pub impl Model for ProcessTimeoutRegister with fn apply(self, state, kind) {
  self.applications[0] = self.applications[0] + 1
  if self.applications[0] > 2 {
    let until = @env.now() + 5100UL
    while @env.now() < until {

    }
  }
  register_model().apply(state, kind)
}

///|
pub impl Model for ProcessTimeoutRegister with fn state_eq(_self, a, b) {
  states_equal(a, b)
}

///|
pub impl Model for ProcessTimeoutRegister with fn state_hash(_self, state) {
  poly_hash(state)
}

///|
test "minimize_by_process: 后续 Unknown 不得伪报不存在见证" {
  let h = History::{
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
  assert_true(check_default(h, Register(register_model())) is Violation(_))
  let result = minimize_by_process_with(
    h,
    ProcessTimeoutRegister::{ applications: [0], },
    MIN_WITNESS,
  )
  assert_true(result.explanation.contains("检查未能给出结论"))
  assert_true(result.explanation.contains("超过时间预算"))
  assert_true(!result.explanation.contains("没有任何子集"))
}
