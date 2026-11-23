// ============================================================================
// audit_jsonl_chunks_wbtest.mbt — 2026-11-23 轮 LC-28（白盒）
//
// gen 在 MAX_GENERATED_OPS 承诺域内（≥ ~865 万条，输出 ≈ 1.08 GB）原生崩溃：
// cmd_gen 的 println(history.to_jsonl()) 把整段历史拼成单个巨型 String，
// native 字符串分配触发访问冲突（exit -1073741819，掉出 0..4 契约）。
// 修复后 to_jsonl_chunks 返回整行块（行间 \n、块尾不带换行、空历史为空数组）：
//   逐块 println 的拼接 == to_jsonl() 本身；
//   CLI 侧（逐块 println + 空历史时多一个 println("")）
//   == 旧 println(to_jsonl()) 逐字节等价
// （旧输出 = N 行 JSON + 末尾一个 println 补的换行，bin-before.exe 取证）。
// ============================================================================

///|
fn lc28_cop(
  id : Int32,
  process : Int32,
  kind : OpKind,
  result : OpResult,
  start : Int64,
  end : Int64,
) -> Operation {
  { id, process, kind, result, start, end, }
}

///|
fn lc28_sample_history() -> History {
  History::{
    operations: [
      lc28_cop(0, 0, Write(1), Ok, 0L, 10L),
      lc28_cop(1, 1, Read, Value(0), 0L, 10L),
      lc28_cop(2, 0, Cas(1, 2), OpResult::Bool(true), 12L, 20L),
      lc28_cop(3, 1, Append(3), Ok, 12L, 20L),
      lc28_cop(4, 1, Pop, Value(3), 22L, 24L),
      lc28_cop(5, 2, Read, Value(-1), 30L, 40L),
      lc28_cop(6, 0, Write(0), Ok, 40L, 50L),
    ],
  }
}

///|
test "lc28: per-chunk println concatenation equals to_jsonl()" {
  let h = lc28_sample_history()
  // 契约主体：对每块 println（块尾补换行）后拼接 == to_jsonl()。
  let mut rebuilt = ""
  for chunk in History::to_jsonl_chunks(h, 3) {
    rebuilt = rebuilt + chunk + "\n"
  }
  assert_eq(rebuilt, h.to_jsonl())
  // 空历史：空数组（CLI 对空历史只打 println("") 的一个换行，与旧版
  // println(to_jsonl()) == println("") 一致）。
  assert_eq(History::to_jsonl_chunks(History::new(), 3).length(), 0)
}

///|
test "lc28: chunk boundaries split by op count, clamped to >= 1" {
  let h = lc28_sample_history()
  let chunks = History::to_jsonl_chunks(h, 3)
  // 7 条操作、每块 3 条 → 3 块（3+3+1）；整除时不得多出空块。
  assert_eq(chunks.length(), 3)
  // 整行块：3 行的块有 2 个内部 \n（split 出 3 段），块尾无换行。
  assert_eq(chunks[0].split("\n").collect().length(), 3)
  assert_eq(chunks[1].split("\n").collect().length(), 3)
  assert_eq(chunks[2].split("\n").collect().length(), 1)
  // 整除：6 条、每块 3 条 → 恰好 2 块。
  let h6 = History::{
    operations: [
      lc28_cop(0, 0, Write(1), Ok, 0L, 1L),
      lc28_cop(1, 1, Write(2), Ok, 0L, 1L),
      lc28_cop(2, 0, Write(3), Ok, 0L, 1L),
      lc28_cop(3, 1, Write(4), Ok, 2L, 3L),
      lc28_cop(4, 0, Write(5), Ok, 2L, 3L),
      lc28_cop(5, 1, Write(6), Ok, 2L, 3L),
    ],
  }
  let exact = History::to_jsonl_chunks(h6, 3)
  assert_eq(exact.length(), 2)
  // 非法块大小钳制为 1：每块恰好一行。
  let singles = History::to_jsonl_chunks(h, 0)
  assert_eq(singles.length(), 7)
  assert_eq(singles[0].split("\n").collect().length(), 1)
}

///|
test "lc28: chunked output round-trips through from_jsonl" {
  let h = lc28_sample_history()
  let mut text = ""
  for chunk in History::to_jsonl_chunks(h, 2) {
    text = text + chunk + "\n"
  }
  let back = match History::from_jsonl(text) {
    Ok(parsed) => parsed
    Err(e) => {
      let BadLine(line_no, reason) = e
      assert_true(
        false,
        msg="round-trip parse failed at line \{line_no}: \{reason}",
      )
      abort("unreachable")
    }
  }
  assert_eq(back.length(), h.length())
  for i, op in h.operations {
    let other = back.operations[i]
    assert_eq(op.id, other.id)
    assert_eq(op.process, other.process)
    assert_eq(op.kind, other.kind)
    assert_eq(op.result, other.result)
    assert_eq(op.start, other.start)
    assert_eq(op.end, other.end)
  }
}

///|
test "lc28: large history splits into bounded chunks instead of one giant string" {
  // 20 万条 ≈ 25 MB 的 JSONL：旧 to_jsonl 仍是单串（尚未达崩溃阈值），
  // 但分块版每块必须被限制在「块大小 × 单行」以内 —— 这是 865 万条
  // （≈ 1.08 GB，实测崩溃点）下不再构造巨型单串的机制保证。
  let n = 200000
  let h = History::new()
  for i in 0..<n {
    h.add(
      lc28_cop(
        i,
        i % 4,
        Write(i % 7),
        Ok,
        (i * 3).to_int64(),
        (i * 3 + 2).to_int64(),
      ),
    )
  }
  let k = 1000
  let chunks = History::to_jsonl_chunks(h, k)
  assert_eq(chunks.length(), n / k)
  // 单行 ≈ 80 字节 → 每块 ≈ 80 KB；断言上界 200 KB（1000 行绝对到不了）。
  let mut max_chunk = 0
  for chunk in chunks {
    if chunk.length() > max_chunk {
      max_chunk = chunk.length()
    }
  }
  assert_true(
    max_chunk < 200000,
    msg="任何一块都不得接近巨型单串规模",
  )
}
