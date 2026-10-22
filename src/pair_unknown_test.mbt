///|
test "pair explanation requires proof and does not cache unknown intervals" {
  let invalid = Operation::{
    id: 0,
    process: 0,
    kind: Write(1),
    result: Ok,
    start: 2L,
    end: 1L,
  }
  let read = Operation::{
    id: 1,
    process: 1,
    kind: Read,
    result: Value(1),
    start: 3L,
    end: 4L,
  }
  let model = register_model()
  let config = CheckConfig::default()
  assert_true(probe_ops([invalid, read], model, config) is Unknown(_))
  let expl = Expl::new()
  assert_true(!expl.pair_explains(invalid, read, model, config))
  assert_eq(expl.pairs.length(), 0)
}

///|
test "unknown pair can be retried under an explicit result assumption" {
  let write = Operation::{
    id: 0,
    process: 0,
    kind: Write(1),
    result: Ok,
    start: 0L,
    end: 1L,
  }
  let read = Operation::{
    id: 1,
    process: 1,
    kind: Read,
    result: Nil,
    start: 2L,
    end: 3L,
  }
  let model = register_model()
  let config = CheckConfig::default()
  let expl = Expl::new()
  assert_true(!expl.pair_explains(write, read, model, config))
  assert_eq(expl.pairs.length(), 0)
  let loose = { ..config, allow_unknown_results: true, }
  assert_true(expl.pair_explains(write, read, model, loose))
  assert_eq(expl.pairs.length(), 1)
}
