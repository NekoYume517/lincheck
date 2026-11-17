// ============================================================================
// json_shape_wbtest.mbt —— `--json` 形状的**白盒**断言（2026-11-17-b 第二轮）
//
// 为什么需要白盒：`cmd/lincheck` 是 main 包，`*_test.mbt` 是黑盒测试（只能看
// `pub` 符号），而 `run()` 只返回退出码 —— stdout 拿不到。于是 `--json` 的
// 形状长期没有任何断言（第一轮报告 §4 把这当成「无可断言观测点」）。
// 这个判定不成立：MoonBit 允许在 main 包里放 `*_wbtest.mbt` 白盒测试，
// `recall/cmd/recall/` 就是先例（17 个 wbtest 直接调私有函数断输出串）。
//
// 本文件先只做一件事：把**已经存在**的私有形状构造器 `json_violation`
// 的输出逐字节钉住，证明这条路走得通。形状本身的分叉（`ops` / `total`）
// 由后续提交按证据处置。
// ============================================================================

///|
/// 一条孤立非法的操作（6 个字段写全，供构造 `Violation` 用）。
fn js_op(
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
/// 违规形状（`verdict = "non-linearizable"`）逐字节断言。
///
/// 顺带锁住三件小事：`reason` 是**可编程分类**（`data-inconsistency` /
/// `concurrency-race`，见 `docs/exit-codes.md`）、`witness` 数组里每条操作的
/// 六个键名与顺序、以及这个形状里承载「历史操作数」的键名（当前是 `total`）。
test "JSON 形状: 违规对象逐字节固定（键名/顺序/分类 token）" {
  let bad = js_op(0, 0, @lib.Cas(1, 2), @lib.Bool(true), 2L, 5L)
  let history = @lib.History::{ operations: [bad], }
  let v = @lib.Violation::{ ops: [bad], depth: 0, explanation: "", }
  // 单操作 + depth 0 → reason 必须是 data-inconsistency（不是 concurrency-race）
  inspect(
    json_violation(v, history, "non-linearizable"),
    content="{\"verdict\":\"non-linearizable\",\"reason\":\"data-inconsistency\",\"total\":1,\"witness\":[{\"id\":0,\"process\":0,\"op\":\"Cas(1->2)\",\"result\":\"Bool(true)\",\"start\":2,\"end\":5}],\"depth\":0}",
  )
  // 见证没能被复现时 verdict 换成 unknown，reason 换成 unconfirmed-witness，
  // 其余字段（total / witness / depth）一字不动 —— 脚本据此区分两种结论。
  inspect(
    json_violation(v, history, "unknown"),
    content="{\"verdict\":\"unknown\",\"reason\":\"unconfirmed-witness\",\"total\":1,\"witness\":[{\"id\":0,\"process\":0,\"op\":\"Cas(1->2)\",\"result\":\"Bool(true)\",\"start\":2,\"end\":5}],\"depth\":0}",
  )
}

///|
/// 多操作违规：`reason` 走 concurrency-race 分支；**顺序由库层决定**。
///
/// `json_violation` 只是照 `v.ops` 的既有顺序渲染，绝不在 CLI 层重排 ——
/// 「见证按 id 升序」这条承诺由库层 `build_violation` / `sort_ops_by_id` 负责
/// （`src/checker_test.mbt` 的 `violation_ops_are_sorted_by_id` 锁着）。这里把
/// 「CLI 是纯渲染」也钉住：顺序变了说明有人在 CLI 层偷偷排序或去重了。
test "JSON 形状: 多操作见证按库层给定顺序渲染（CLI 不重排）" {
  let sorted_ops = [
    js_op(0, 0, @lib.Write(1), @lib.Ok, 0L, 10L),
    js_op(1, 1, @lib.Write(2), @lib.Ok, 12L, 20L),
    js_op(2, 0, @lib.Read, @lib.Value(1), 30L, 40L),
  ]
  let history = @lib.History::{ operations: sorted_ops, }
  let v = @lib.Violation::{ ops: sorted_ops, depth: 2, explanation: "", }
  inspect(
    json_violation(v, history, "non-linearizable"),
    content="{\"verdict\":\"non-linearizable\",\"reason\":\"concurrency-race\",\"total\":3,\"witness\":[{\"id\":0,\"process\":0,\"op\":\"W=1\",\"result\":\"Ok\",\"start\":0,\"end\":10},{\"id\":1,\"process\":1,\"op\":\"W=2\",\"result\":\"Ok\",\"start\":12,\"end\":20},{\"id\":2,\"process\":0,\"op\":\"R\",\"result\":\"Value(1)\",\"start\":30,\"end\":40}],\"depth\":2}",
  )
  // 故意给一个乱序见证：输出必须原样照抄（若这里变成 0,1 的顺序，说明 CLI 层加了排序）
  let unsorted_ops = [
    js_op(1, 1, @lib.Write(2), @lib.Ok, 12L, 20L),
    js_op(0, 0, @lib.Write(1), @lib.Ok, 0L, 10L),
  ]
  let history2 = @lib.History::{ operations: unsorted_ops, }
  let v2 = @lib.Violation::{ ops: unsorted_ops, depth: 1, explanation: "", }
  inspect(
    json_violation(v2, history2, "non-linearizable"),
    content="{\"verdict\":\"non-linearizable\",\"reason\":\"concurrency-race\",\"total\":2,\"witness\":[{\"id\":1,\"process\":1,\"op\":\"W=2\",\"result\":\"Ok\",\"start\":12,\"end\":20},{\"id\":0,\"process\":0,\"op\":\"W=1\",\"result\":\"Ok\",\"start\":0,\"end\":10}],\"depth\":1}",
  )
}

// ============================================================================
// LC-16：同一个量在整条 CLI 里只能有一个键名
// ============================================================================
//
// **修复前**的清点（`evidence/json-shape-inventory-before.txt`，全部是实测输出；
// 修复后的实测见 `evidence/json-shape-inventory-after.txt`）：
//
//   check    --json  线性一致   {"verdict":"linearizable","ops":3}          ← ops（修复前）
//   check    --json  违规       {"verdict":"non-linearizable",…,"total":3,…} ← total
//   minimize --json  线性一致   {"verdict":"linearizable","total":3}         ← total
//   minimize --json  无见证     {…,"total":1,…}                              ← total
//
// 「历史操作数」这一个量有 `ops` 与 `total` 两个名字，而且分叉发生在**同一条
// 命令内部**（`check` 的两个分支）。脚本按 `jq .total` 取值时，历史合法这一支
// 拿到 null；按 `jq .ops` 取值时，违规这一支拿到 null。整条 CLI 里 `total`
// 是多数派（4/5 个形状）且是 `docs/exit-codes.md` 展示给用户的那个名字，
// 所以修法是把 `ops` 收敛成 `total`，并让两条命令共用一个构造器。

///|
/// `linearizable` 形状：历史操作数的键名必须与违规形状一致（`total`）。
test "LC-16: linearizable 的『历史操作数』键名必须与 violation 形状一致" {
  inspect(
    linearizable_json(3),
    content="{\"verdict\":\"linearizable\",\"total\":3}",
  )
  // 0 条操作也要走同一条形状（空历史是平凡线性一致，不是特例）
  inspect(
    linearizable_json(0),
    content="{\"verdict\":\"linearizable\",\"total\":0}",
  )
}
