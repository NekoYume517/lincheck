// 第十一轮审计：搜索、可视化与 JSON 的剩余极值覆盖。
// 这些用例都有独立不变量或独立 oracle，不复用被测计算来得出期望值。

///|
fn edge_op(
  id : Int32,
  process : Int32,
  kind : OpKind,
  result : OpResult,
  start : Int64,
  end : Int64,
) -> Operation {
  Operation::{ id, process, kind, result, start, end, }
}

///|
test "搜索：极值时间与重复 id 在四档缓存下见证均可重放" {
  let histories = [
    History::{
      operations: [
        edge_op(
          -2147483648,
          0,
          Write(1),
          Ok,
          -9223372036854775808L,
          -9223372036854775807L,
        ),
        edge_op(
          2147483647,
          1,
          Write(2),
          Ok,
          9223372036854775804L,
          9223372036854775805L,
        ),
        edge_op(
          0,
          0,
          Read,
          Value(1),
          9223372036854775806L,
          9223372036854775807L,
        ),
      ],
    },
    History::{
      operations: [
        edge_op(7, 0, Write(1), Ok, 0L, 10L),
        edge_op(7, 1, Write(2), Ok, 0L, 10L),
        edge_op(7, 2, Read, Value(0), 20L, 30L),
      ],
    },
  ]
  for h in histories {
    for max_states in [0, 1, 3, 200000] {
      let config = CheckConfig::{
        time_budget_ms: 0,
        max_states,
        allow_unknown_results: false,
      }
      match check_with(h, register_model(), config) {
        Violation(v) =>
          // 缓存键必须按操作下标区分剩余集合，重复 id 不得吞掉真正的失败点。
          match check_with(ops_to_history(v.ops), register_model(), config) {
            Violation(_) => ()
            _ => fail("见证子集在相同缓存档位下不能重放违规")
          }
        _ => fail("独立构造的违规历史被误判")
      }
    }
  }
}

///|
test "时间轴：完整 Int64 两端与近 2^53 的列号均有界且保序" {
  let cases : Array[(Int64, Int64, Array[Int64])] = [
    (
      -9223372036854775808L,
      9223372036854775807L,
      [
        -9223372036854775808L, -9223372036854775807L, -1L, 0L, 1L, 9223372036854775806L,
        9223372036854775807L,
      ],
    ),
    (
      9007199254740000L,
      9007199254741000L,
      [
        9007199254740000L, 9007199254740001L, 9007199254740002L, 9007199254740003L,
        9007199254740991L, 9007199254740992L, 9007199254740993L, 9007199254741000L,
      ],
    ),
  ]
  for entry in cases {
    let (tmin, tmax, timestamps) = entry
    let span = tmax - tmin
    let mut previous = 0
    for t in timestamps {
      let col = col_of(t, tmin, span, 48)
      assert_true(col >= 0 && col <= 48)
      assert_true(col >= previous)
      previous = col
    }
  }
}

///|
test "时间约束：极值/零长/重复 id 的计数与独立 O(n²) 一致" {
  let ops = [
    edge_op(
      -2147483648,
      0,
      Write(1),
      Ok,
      -9223372036854775808L,
      -9223372036854775808L,
    ),
    edge_op(7, 1, Write(2), Ok, -5L, 5L),
    edge_op(7, 2, Read, Value(2), 5L, 5L),
    edge_op(
      2147483647,
      3,
      Read,
      Value(2),
      9223372036854775806L,
      9223372036854775807L,
    ),
  ]
  let mut expected = 0L
  for a in ops {
    for b in ops {
      if a != b && happens_before(a, b) {
        expected = expected + 1L
      }
    }
  }
  assert_eq(count_order_facts(ops), expected)
  assert_eq(count_order_facts(ops), 5L)
}

///|
fn edge_precision_row(
  start : String,
  end : String,
) -> Result[History, HistoryError] {
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
test "JSON：更多 Int64 十进制边界与独立期望值一致" {
  for
    pair in [
      ("92233720368547758070e-1", 9223372036854775807L),
      ("-92233720368547758070e-1", -9223372036854775807L),
      ("-92233720368547758080e-1", -9223372036854775808L),
      ("9223372036854775807.000e0", 9223372036854775807L),
      ("90071992547409930000e-4", 9007199254740993L),
      ("1000000000000000000000000000000e-30", 1L),
      ("-0.000e-999999999999999999", 0L),
    ] {
    match edge_precision_row(pair.0, pair.0) {
      Ok(h) => {
        assert_eq(h.operations[0].start, pair.1)
        assert_eq(h.operations[0].end, pair.1)
      }
      Err(_) => fail("范围内精确整数被误拒：" + pair.0)
    }
  }
  for
    invalid in [
      "92233720368547758080e-1", "-92233720368547758090e-1", "90071992547409930001e-4",
      "9223372036854775807.000000000000000001", "1.000000000000000001", "10e999999999999999999",
    ] {
    assert_true(edge_precision_row(invalid, invalid) is Err(_))
  }
}

///|
test "JSON：Int32 全字段精确解析且重复键按最后值恢复原文" {
  let text = "{\"id\":21474836470e-1,\"process\":-21474836480e-1,\"kind\":{\"tag\":\"Cas\",\"expected\":-21474836480e-1,\"new\":21474836470e-1},\"result\":{\"tag\":\"Bool\",\"value\":true},\"start\":1e999,\"start\":9007199254740993,\"end\":9007199254740995,\"extra\":[\"-1e999\",{\"nested\":[1.0,2e1]}]}"
  match History::from_jsonl(text) {
    Ok(h) => {
      let op = h.operations[0]
      assert_eq(op.id, 2147483647)
      assert_eq(op.process, -2147483648)
      assert_eq(op.kind, Cas(-2147483648, 2147483647))
      assert_eq(op.start, 9007199254740993L)
      assert_eq(op.end, 9007199254740995L)
    }
    Err(_) => fail("合法 Int32/Int64 或 last-wins 数字原文恢复失败")
  }
}
