///|
fn membership_history(result : OpResult) -> History {
  History::{
    operations: [
      { id: 0, process: 0, kind: Append(1), result: Ok, start: 0L, end: 1L, },
      { id: 1, process: 1, kind: Append(63), result: Ok, start: 2L, end: 3L, },
      { id: 2, process: 2, kind: Read, result, start: 4L, end: 5L, },
    ],
  }
}

///|
test "set membership: empty set accepts only the empty sentinel" {
  let invalid : Array[OpResult] = [Value(42), Value(0), Ok, Empty, Bool(false)]
  for result in invalid {
    let h = History::{
      operations: [
        { id: 0, process: 0, kind: Read, result, start: 0L, end: 1L, },
      ],
    }
    assert_true(check_default(h, Set(set_model())) is Violation(_))
  }
  let empty = History::{
    operations: [
      { id: 0, process: 0, kind: Read, result: Value(-1), start: 0L, end: 1L, },
    ],
  }
  assert_true(check_default(empty, Set(set_model())) is Linearizable)
}

///|
test "set membership: domain membership alone does not make a read valid" {
  for value in [-1, 0, 2, 32, 62, 64] {
    assert_true(
      check_default(membership_history(Value(value)), Set(set_model()))
      is Violation(_),
    )
  }
}

///|
test "set membership: any present member is valid through concrete and enum dispatch" {
  for value in [1, 63] {
    let h = membership_history(Value(value))
    assert_true(
      check_with(h, set_model(), CheckConfig::default()) is Linearizable,
    )
    assert_true(check_default(h, Set(set_model())) is Linearizable)
  }
}

///|
test "set membership: read rejects invalid result shapes" {
  let invalid : Array[OpResult] = [Ok, Empty, Bool(true), Bool(false)]
  for result in invalid {
    assert_true(
      check_default(membership_history(result), Set(set_model()))
      is Violation(_),
    )
  }
}

///|
test "set membership: unknown reads require explicit loose mode" {
  let h = membership_history(Nil)
  assert_true(check_default(h, Set(set_model())) is Unknown(_))
  let config = { ..CheckConfig::default(), allow_unknown_results: true, }
  assert_true(check_with(h, set_model(), config) is Linearizable)
}

///|
test "set membership: removed members cannot be read later" {
  let h = membership_history(Value(1))
  h.add({
    id: 3,
    process: 0,
    kind: Pop,
    result: Bool(true),
    start: 6L,
    end: 7L,
  })
  h.add({ id: 4, process: 2, kind: Read, result: Value(1), start: 8L, end: 9L, })
  assert_true(check_default(h, Set(set_model())) is Violation(_))
}

///|
test "set membership: generated consistent reads have concrete valid results" {
  let h = generate_consistent(set_model(), GenConfig::new(3, 10, 42, 0.0))
  for op in h.operations {
    assert_true(!(op.result is Nil))
  }
  assert_true(
    check_with(h, set_model(), CheckConfig::default()) is Linearizable,
  )
}
