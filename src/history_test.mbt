///|
/// # history.mbt 的测试
///
/// 覆盖：
/// - 基本集合操作（new/add/length/sort_by_start）
/// - happens_before / concurrent 的真值表（含 end == start 的边界）
/// - JSONL 往返（round-trip）
/// - 4 份 examples 文件的逐字内容能正确解析
/// - 非法 JSONL 的行号与原因

// ============================================================
// 辅助：构造操作
// ============================================================

fn hop(
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
fn hist(ops : Array[Operation]) -> History {
  let h = History::new()
  for op in ops {
    h.add(op)
  }
  h
}

///|
/// 调用 `History::from_jsonl` 并把 `Result` 展开成便于断言的形式。
fn parse(text : StringView) -> Result[History, String] {
  try {
    let r = History::from_jsonl(text)
    match r {
      Ok(h) => Ok(h)
      Err(BadLine(line, reason)) =>
        Err("line " + line.to_string() + ": " + reason)
    }
  } catch {
    _ => Err("unexpected raise")
  }
}

// ============================================================
// 基础容器
// ============================================================

///|
test "history_new_is_empty" {
  let h = History::new()
  inspect(h.length(), content="0")
  inspect(h.to_jsonl(), content="")
}

///|
test "history_add_increments_length" {
  let h = hist([
    hop(0, 0, Write(1), OpResult::Ok, 0L, 10L),
    hop(1, 1, Read, Value(1), 11L, 20L),
  ])
  inspect(h.length(), content="2")
  inspect(format_op_kind(h.operations[0].kind), content="Write(1)")
  inspect(format_op_result(h.operations[1].result), content="-> 1")
}

///|
test "history_sort_by_start_is_stable_on_id" {
  let h = hist([
    hop(2, 0, Write(2), OpResult::Ok, 10L, 20L),
    hop(0, 0, Write(0), OpResult::Ok, 0L, 5L),
    hop(1, 0, Write(1), OpResult::Ok, 10L, 15L),
  ])
  let s = h.sort_by_start()
  let sb = StringBuilder()
  for i, op in s.operations {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(op.id.to_string())
  }
  // start 相同（10L）时按 id 升序：1 在 2 前面
  inspect(sb.to_string(), content="0,1,2")
  // 原历史不被修改
  inspect(h.operations[0].id, content="2")
}

///|
/// 比较器不得用减法：`start` 是完整 Int64 范围，两端的差值会溢出，
/// 溢出后的比较结果破坏全序（这里会直接倒序）。
test "history_sort_by_start 在 Int64 极值下仍按 start 升序" {
  let h = hist([
    hop(
      0,
      0,
      Write(1),
      OpResult::Ok,
      9223372036854775807L,
      9223372036854775807L,
    ),
    hop(
      1,
      0,
      Write(2),
      OpResult::Ok,
      -9223372036854775807L,
      -9223372036854775807L,
    ),
  ])
  let s = h.sort_by_start()
  inspect(s.operations[0].id, content="1")
  inspect(s.operations[1].id, content="0")
}

// ============================================================
// happens_before / concurrent
// ============================================================

///|
test "happens_before_true_when_a_ends_first" {
  let a = hop(0, 0, Write(1), OpResult::Ok, 0L, 10L)
  let b = hop(1, 0, Read, Value(1), 20L, 30L)
  assert_true(happens_before(a, b))
  assert_true(!happens_before(b, a))
}

///|
test "happens_before_false_when_overlapping" {
  let a = hop(0, 0, Write(1), OpResult::Ok, 0L, 10L)
  let b = hop(1, 0, Write(2), OpResult::Ok, 5L, 15L)
  assert_true(!happens_before(a, b))
  assert_true(!happens_before(b, a))
  assert_true(concurrent(a, b))
}

///|
test "happens_before_strict_on_touching_boundary" {
  // a.end == b.start：视为并发（响应与调用可能同时刻）
  let a = hop(0, 0, Write(1), OpResult::Ok, 0L, 10L)
  let b = hop(1, 0, Read, Value(1), 10L, 20L)
  assert_true(!happens_before(a, b))
  assert_true(concurrent(a, b))
}

///|
test "concurrent_symmetric_and_nested" {
  // b 完全嵌套在 a 内部
  let a = hop(0, 0, Read, Value(0), 0L, 30L)
  let b = hop(1, 1, Write(1), OpResult::Ok, 5L, 10L)
  assert_true(concurrent(a, b))
  assert_true(concurrent(b, a))
  assert_true(!happens_before(a, b))
  assert_true(!happens_before(b, a))
}

///|
test "concurrent_false_for_disjoint" {
  let a = hop(0, 0, Write(1), OpResult::Ok, 0L, 10L)
  let b = hop(1, 0, Write(2), OpResult::Ok, 12L, 20L)
  assert_true(!concurrent(a, b))
  assert_true(happens_before(a, b))
}

// ============================================================
// JSONL 往返
// ============================================================

///|
test "jsonl_single_write_line_matches_contract" {
  // 与 API.md 里给出的示例逐字一致
  let h = hist([hop(0, 0, Write(1), OpResult::Ok, 0L, 10L)])
  inspect(
    h.to_jsonl(),
    content="{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":10}\n",
  )
}

///|
test "jsonl_all_kinds_and_results_roundtrip" {
  let h = hist([
    hop(0, 0, Write(7), OpResult::Ok, 0L, 1L),
    hop(1, 0, Read, Value(7), 1L, 2L),
    hop(2, 0, Cas(7, 8), OpResult::Bool(true), 2L, 3L),
    hop(3, 0, Cas(9, 10), OpResult::Bool(false), 3L, 4L),
    hop(4, 0, Append(3), OpResult::Ok, 4L, 5L),
    hop(5, 0, Pop, Empty, 5L, 6L),
    hop(6, 0, Pop, Nil, 6L, 7L),
  ])
  let text = h.to_jsonl()
  match parse(text) {
    Ok(back) => {
      inspect(back.length(), content="7")
      // 逐字段比对
      for i, op in h.operations {
        let got = back.operations[i]
        assert_true(got.id == op.id)
        assert_true(got.process == op.process)
        assert_true(got.kind == op.kind)
        assert_true(got.result == op.result)
        assert_true(got.start == op.start)
        assert_true(got.end == op.end)
      }
      // 再序列化一次应当完全相同（序列化是确定的）
      inspect(back.to_jsonl(), content=text)
    }
    Err(e) => inspect(e, content="<应当解析成功>")
  }
}

///|
test "jsonl_skips_blank_lines_but_counts_line_numbers" {
  let text = "\n\n{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":0,\"end\":1}\n\n"
  match parse(text) {
    Ok(h) => inspect(h.length(), content="1")
    Err(e) => inspect(e, content="<应当解析成功>")
  }
}

///|
test "jsonl_empty_text_is_empty_history" {
  match parse("") {
    Ok(h) => inspect(h.length(), content="0")
    Err(e) => inspect(e, content="<应当解析成功>")
  }
}

// ============================================================
// 非法输入
// ============================================================

///|
test "jsonl_rejects_malformed_json_with_line_number" {
  let text = "{\"id\":0,\"process\":0,\"kind\":{\"tag\":\"Read\"},\"result\":{\"tag\":\"Value\",\"value\":0},\"start\":0,\"end\":1}\nnot json\n"
  match parse(text) {
    Ok(_) => inspect("<应当失败>", content="")
    Err(e) => inspect(e.contains("line 2"), content="true")
  }
}

///|
test "jsonl_rejects_non_object_line" {
  match parse("[1,2,3]\n") {
    Ok(_) => inspect("<应当失败>", content="")
    Err(e) => inspect(e.contains("必须是一个 JSON 对象"), content="true")
  }
}

///|
test "jsonl_rejects_unknown_kind_tag" {
  let text =
    #|{"id":0,"process":0,"kind":{"tag":"Explode"},"result":{"tag":"Ok"},"start":0,"end":1}
    #|
  match parse(text) {
    Ok(_) => inspect("<应当失败>", content="")
    Err(e) => inspect(e.contains("未知的操作 tag"), content="true")
  }
}

///|
test "jsonl_rejects_missing_timestamp" {
  let text =
    #|{"id":0,"process":0,"kind":{"tag":"Read"},"result":{"tag":"Value","value":0}}
    #|
  match parse(text) {
    Ok(_) => inspect("<应当失败>", content="")
    Err(e) => inspect(e.contains("start/end"), content="true")
  }
}

// ============================================================
// 4 份 examples 文件（逐字内嵌，与 examples/*.jsonl 相同）
// ============================================================

///|
/// examples/register_ok.jsonl
const EXAMPLE_REGISTER_OK : String =
  #|{"id":0,"process":0,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":0,"end":10}
  #|{"id":1,"process":1,"kind":{"tag":"Write","value":2},"result":{"tag":"Ok"},"start":5,"end":15}
  #|{"id":2,"process":0,"kind":{"tag":"Read"},"result":{"tag":"Value","value":2},"start":20,"end":30}
  #|

///|
/// examples/register_bad.jsonl（两次写不重叠：10 < 12）
const EXAMPLE_REGISTER_BAD : String =
  #|{"id":0,"process":0,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":0,"end":10}
  #|{"id":1,"process":1,"kind":{"tag":"Write","value":2},"result":{"tag":"Ok"},"start":12,"end":20}
  #|{"id":2,"process":0,"kind":{"tag":"Read"},"result":{"tag":"Value","value":1},"start":30,"end":40}
  #|

///|
/// examples/stale_read.jsonl
const EXAMPLE_STALE_READ : String =
  #|{"id":0,"process":0,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":0,"end":10}
  #|{"id":1,"process":0,"kind":{"tag":"Read"},"result":{"tag":"Value","value":1},"start":10,"end":20}
  #|{"id":2,"process":1,"kind":{"tag":"Read"},"result":{"tag":"Value","value":0},"start":30,"end":40}
  #|

///|
/// examples/concurrent_ok.jsonl
const EXAMPLE_CONCURRENT_OK : String =
  #|{"id":0,"process":0,"kind":{"tag":"Read"},"result":{"tag":"Value","value":0},"start":0,"end":30}
  #|{"id":1,"process":1,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":5,"end":10}
  #|{"id":2,"process":2,"kind":{"tag":"Write","value":2},"result":{"tag":"Ok"},"start":12,"end":18}
  #|{"id":3,"process":3,"kind":{"tag":"Read"},"result":{"tag":"Value","value":2},"start":20,"end":35}
  #|

///|
test "example_files_parse_to_expected_shapes" {
  match parse(EXAMPLE_REGISTER_OK) {
    Ok(h) => {
      inspect(h.length(), content="3")
      // 两次写重叠 → 并发；读在两次写之后 → 不并发
      let (w0, w1, r) = (h.operations[0], h.operations[1], h.operations[2])
      assert_true(concurrent(w0, w1))
      assert_true(happens_before(w1, r))
    }
    Err(e) => inspect(e, content="<应当解析成功>")
  }
  match parse(EXAMPLE_REGISTER_BAD) {
    Ok(h) => {
      inspect(h.length(), content="3")
      let (w0, w1, r) = (h.operations[0], h.operations[1], h.operations[2])
      // 关键：两次写不重叠，w1 必然排在 w0 之后
      assert_true(happens_before(w0, w1))
      assert_true(happens_before(w1, r))
    }
    Err(e) => inspect(e, content="<应当解析成功>")
  }
  match parse(EXAMPLE_STALE_READ) {
    Ok(h) => inspect(h.length(), content="3")
    Err(e) => inspect(e, content="<应当解析成功>")
  }
  match parse(EXAMPLE_CONCURRENT_OK) {
    Ok(h) => inspect(h.length(), content="4")
    Err(e) => inspect(e, content="<应当解析成功>")
  }
}

///|
test "example_files_jsonl_roundtrip_is_identity" {
  let all : Array[String] = [
    EXAMPLE_REGISTER_OK,
    EXAMPLE_REGISTER_BAD,
    EXAMPLE_STALE_READ,
    EXAMPLE_CONCURRENT_OK,
  ]
  for text in all {
    match parse(text) {
      Ok(h) => inspect(h.to_jsonl() == text, content="true")
      Err(e) => inspect(e, content="<应当解析成功>")
    }
  }
}
