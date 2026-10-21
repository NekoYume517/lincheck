///|
fn precision_row(start : String, end : String) -> Result[History, HistoryError] {
  History::from_jsonl(
    "{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":" +
    start +
    ",\"end\":" +
    end +
    "}",
  ) catch {
    _ => Err(BadLine(-1, "unexpected exception"))
  }
}

///|
test "timestamp precision: JSONL preserves full Int64 timestamp range" {
  for
    value in [
      9007199254740993L, 9007199254740995L, 9223372036854775807L, -9223372036854775808L,
    ] {
    let h = History::{
      operations: [
        {
          id: 0,
          process: 0,
          kind: Read,
          result: Value(0),
          start: value,
          end: value,
        },
      ],
    }
    match History::from_jsonl(h.to_jsonl()) {
      Ok(parsed) => {
        assert_eq(parsed.operations[0].start, value)
        assert_eq(parsed.operations[0].end, value)
      }
      Err(_) => assert_true(false)
    }
  }
}

///|
test "timestamp precision: rounding cannot make a stale read linearizable" {
  let h = History::{
    operations: [
      {
        id: 0,
        process: 0,
        kind: Write(1),
        result: Ok,
        start: 9007199254740992L,
        end: 9007199254740995L,
      },
      {
        id: 1,
        process: 1,
        kind: Read,
        result: Value(0),
        start: 9007199254740996L,
        end: 9007199254740998L,
      },
    ],
  }
  assert_true(check_default(h, Register(register_model())) is Violation(_))
  match History::from_jsonl(h.to_jsonl()) {
    Ok(parsed) =>
      assert_true(
        check_default(parsed, Register(register_model())) is Violation(_),
      )
    Err(_) => assert_true(false)
  }
}

///|
test "timestamp precision: exact integer decimal and exponent forms remain accepted" {
  for
    pair in [
      ("1.0", 1L),
      ("1e2", 100L),
      ("1000e-3", 1L),
      ("-0.000", 0L),
      ("0e99999999999999999999999999999", 0L),
      ("9.007199254740993e15", 9007199254740993L),
      ("9223372036854775807.000", 9223372036854775807L),
      ("-92233720368547758080e-1", -9223372036854775808L),
    ] {
    match precision_row(pair.0, pair.0) {
      Ok(parsed) => assert_eq(parsed.operations[0].start, pair.1)
      Err(_) => {
        println(pair.0)
        assert_true(false)
      }
    }
  }
}

///|
test "timestamp precision: overflow and hidden fractional digits are rejected" {
  for
    invalid in [
      "9223372036854775808", "-9223372036854775809", "18446744073709551617", "9223372036854775807.0000000000000001",
      "9007199254740993.1", "1.0000000000000001", "0.99999999999999999", "1e-4000",
      "1e4000", "10e99999999999999999999999999999", "10e-99999999999999999999999999999",
    ] {
    assert_true(precision_row(invalid, invalid) is Err(_))
  }
}

///|
test "timestamp precision: small exact integer JSON forms are preserved" {
  for value in [-100000L, -1L, 0L, 1L, 100000L, 2147483647L, -2147483648L] {
    match precision_row(value.to_string(), value.to_string()) {
      Ok(parsed) => assert_eq(parsed.operations[0].start, value)
      Err(_) => assert_true(false)
    }
  }
}

///|
test "timestamp precision: lexical preservation keeps strings escaped keys and duplicate keys intact" {
  let text = "{\"id\":0,\"id\":1.0,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"st\\u0061rt\":9007199254740993,\"end\":9007199254740995,\"extra\":[\"123e45\\\"678\",{\"123\":\"-123\"},1.0]}"
  match History::from_jsonl(text) {
    Ok(parsed) => {
      assert_eq(parsed.operations[0].id, 1)
      assert_eq(parsed.operations[0].start, 9007199254740993L)
      assert_eq(parsed.operations[0].end, 9007199254740995L)
    }
    Err(_) => assert_true(false)
  }
}

///|
test "timestamp precision: integer IDs also reject fractions hidden by Double rounding" {
  let invalid = "{\"id\":1.0000000000000001,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":0,\"end\":1}"
  assert_true(History::from_jsonl(invalid) is Err(_))
}

///|
test "timestamp precision: decimal normalization supports both Int64 boundaries" {
  for
    pair in [
      ("9.223372036854775807e18", 9223372036854775807L),
      ("-9.223372036854775808e18", -9223372036854775808L),
      ("100000000000000000000000000e-26", 1L),
      ("0e-99999999999999999999999999999", 0L),
    ] {
    match precision_row(pair.0, pair.0) {
      Ok(parsed) => assert_eq(parsed.operations[0].start, pair.1)
      Err(_) => assert_true(false)
    }
  }
  for invalid in ["9.223372036854775808e18", "-9.223372036854775809e18", "1e-1"] {
    assert_true(precision_row(invalid, invalid) is Err(_))
  }
}
