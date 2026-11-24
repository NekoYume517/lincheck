// ============================================================================
// lc33_single_json_wbtest.mbt —— 一条命令只产出**一个** JSON 文档
// （2026-11-24 审计 LC-33 的回归测试）
//
// 现象（`cmd_minimize` 的 `MinViolation` 分支，见证未能被复现时）：
//
//   $ lincheck minimize --history h.jsonl --model register --json
//   {"verdict":"unknown","reason":"unconfirmed-witness","total":…,"witness":[…],"depth":…}
//   {"note":"见证未能被复现","reason":"unconfirmed-witness"}     ← 第二份文档
//
// 根因：`confirmed == false` 时补打了一行 note JSON。而 `API.md` §7.1 的四种
// 形状里没有这个形状，`json_shape_wbtest.mbt` 也没锁它。
//
// 为什么多余：它承载的语义已经由 `verdict=unknown` + `reason=unconfirmed-witness`
// + 退出码 3 三重表达。对 `jq .verdict` 这类「读一个文档」的脚本是多余输出，
// 对按文档数分支的脚本则是一次**无文档可依**的分支（第二份文档的键集与前一份
// 完全不同，同一套解析器必然在其中一份上报错）。
//
// 契约：`--json` 出口的每个 verdict 都只对应一个 JSON 对象、一行、以 `}` 结尾；
// 文档之间不许有 `note` 这种形状表以外的追加。
// ============================================================================

///|
/// 构造一个最小违规见证（与 `json_shape_wbtest.mbt` 的 `js_op` 同形，
/// 但独立命名以免同包重定义）。
fn lc33_op(
  id : Int32,
  process : Int32,
  kind : @lib.OpKind,
  result : @lib.OpResult,
  start : Int64,
  end : Int64,
) -> @lib.Operation {
  @lib.Operation::{ id, process, kind, result, start, end, }
}

///|
/// 每个 verdict 的文档都必须**恰好一行**且不自带尾换行 —— 这是
/// 「一条命令一个文档」这个承诺在字节层唯一可断言的形式。
test "LC-33: minimize --json 的每个 verdict 都只是一个单行 JSON 对象" {
  let bad = lc33_op(0, 0, @lib.Cas(1, 2), @lib.Bool(true), 2L, 5L)
  let history = @lib.History::{ operations: [bad], }
  let v = @lib.Violation::{ ops: [bad], depth: 0, explanation: "", }
  for verdict in ["non-linearizable", "unknown"] {
    let doc = json_violation(v, history, verdict)
    let parts : Array[StringView] = doc.split("\n").collect()
    assert_eq(parts.length(), 1)
    assert_true(doc[0] == '{')
    assert_true(doc[doc.length() - 1] == '}')
    // 旧实现追加的第二份文档带 `note` 键；形状表里没有这个键，故它不该出现
    // 在任何 `--json` 文档里。
    assert_false(doc.contains("\"note\""))
  }
}

///|
/// 「见证未能被复现」这个语义必须由**前一份**文档自己表达完整：脚本只读
/// 一个文档时，也必须能区分「已证实违规」与「没能复现」。
///
/// 这条防的是「删掉第二份文档时顺手把信息也删了」：删文档必须不丢语义。
test "LC-33: unconfirmed 语义由 verdict + reason 双字段承载" {
  let bad = lc33_op(0, 0, @lib.Cas(1, 2), @lib.Bool(true), 2L, 5L)
  let history = @lib.History::{ operations: [bad], }
  let v = @lib.Violation::{ ops: [bad], depth: 0, explanation: "", }
  let confirmed = json_violation(v, history, "non-linearizable")
  let unconfirmed = json_violation(v, history, "unknown")
  assert_true(confirmed.contains("\"verdict\":\"non-linearizable\""))
  assert_true(unconfirmed.contains("\"verdict\":\"unknown\""))
  assert_true(unconfirmed.contains("\"reason\":\"unconfirmed-witness\""))
  // 两份文档的键集必须完全一致（只是取值不同）——同一条命令的出口形状不能
  // 随结论漂移，否则脚本无法用一套解析器读完两个分支。
  assert_true(
    confirmed.split("\"verdict\":").collect().length() ==
    unconfirmed.split("\"verdict\":").collect().length(),
  )
  assert_true(confirmed.contains("\"witness\":["))
  assert_true(unconfirmed.contains("\"witness\":["))
}
