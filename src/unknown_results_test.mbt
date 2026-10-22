///|
test "strict unknown results are incomplete evidence before search" {
  let history = History::{
    operations: [
      Operation::{
        id: 0,
        process: 0,
        kind: Read,
        result: Nil,
        start: 0L,
        end: 1L,
      },
      Operation::{
        id: 1,
        process: 0,
        kind: Read,
        result: Nil,
        start: 2L,
        end: 3L,
      },
    ],
  }
  let config = CheckConfig::default()
  let (outcome, stats) = check_with_stats(history, register_model(), config)
  match outcome {
    Unknown(reason) => assert_true(reason.contains("2 个未知结果"))
    _ => fail("incomplete response evidence must be Unknown")
  }
  assert_eq(stats.explored, 0)
  assert_eq(stats.cache_size, 0)
  assert_true(!stats.timed_out)
  assert_true(check_with(history, register_model(), config) is Unknown(_))
  let minimized = minimize(history, Register(register_model()), config)
  assert_eq(minimized.ops.length(), 2)
  assert_true(minimized.explanation.contains("无法最小化"))
}
