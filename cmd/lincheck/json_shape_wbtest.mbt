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

// ============================================================================
// LC-18：`depth` 只属于「存在见证」的形状
// ============================================================================
//
// 上一轮把「`minimize --json` 的 NoWitness 形状没有 `depth`」记成可断言性小瑕疵
// 并略过。白盒可用之后重新判：`depth` 的定义是「**该见证**的最长一致前缀长度」
// （`Violation.depth`），而 NoWitness 形状里根本没有见证（`witness:[]`）。
// 补一个 `depth:0` 会把「没有见证」写成「有见证且前缀为空」—— 后者正是
// `violation_reason` 里 data-inconsistency 的判据，两者不是一回事。
// 所以结论是**保留缺席**，但必须①写进 API.md；②用断言锁住它不会被人「补上」。

///|
/// 「没有结论」形状：`reason` 是散文，且不带 `total` / `depth`。
test "LC-18: unknown 形状只有 verdict+reason（reason 是散文，不是分类 token）" {
  let out = unknown_json(
    "超过时间预算 1ms（已探索 1 个搜索节点）",
  )
  inspect(
    out,
    content="{\"verdict\":\"unknown\",\"reason\":\"超过时间预算 1ms（已探索 1 个搜索节点）\"}",
  )
  assert_false(out.contains("\"total\""))
  assert_false(out.contains("\"depth\""))
  assert_false(out.contains("\"witness\""))
}

///|
/// NoWitness 形状：`witness` 必须是空数组，**且整个对象不出现 `depth`**。
test "LC-18: NoWitness 形状不含 depth（无见证就没有前缀长度）" {
  let out = no_witness_json(1, "concurrency-race")
  inspect(
    out,
    content="{\"verdict\":\"non-linearizable\",\"total\":1,\"witness\":[],\"reason\":\"no-explainable-witness\",\"cause\":\"concurrency-race\"}",
  )
  // 有人「顺手补上」depth 时这里必须红：那会把「无见证」写成「有见证且前缀为空」
  assert_false(out.contains("\"depth\""))
  // 与违规形状对照：那个形状有见证，所以必须有 depth
  let bad = js_op(0, 0, @lib.Cas(1, 2), @lib.Bool(true), 2L, 5L)
  let history = @lib.History::{ operations: [bad], }
  let v = @lib.Violation::{ ops: [bad], depth: 0, explanation: "", }
  assert_true(
    json_violation(v, history, "non-linearizable").contains("\"depth\""),
  )
}

// ============================================================================
// LC-26：NoWitness 的成因在文本与 JSON 两个出口上必须是**同一份**结论
// ============================================================================
//
// 旧实现：文本走 `no_witness_reason_text(n, check(history, cfg))`（真的再查
// 一次），JSON 走 `no_witness_json(n)` 并写死 `reason:"no-explainable-witness"`。
// 两个出口各写一套判据：低预算抖动时文本说「成因未能确定」、JSON 却没有任何
// 位置表达这件事；而且 JSON 路径省掉了这次复检，同一条命令的两种输出格式
// 工作量都不一样。
//
// 现在两个出口读同一个 `cause`（`no_witness_cause`）：`reason` 仍是形状 token
// （API.md §7.1），成因落在 `cause` 键上。为什么成因不塞进 `reason`：它的取值
// 里有 `unknown`，写进 `verdict":"non-linearizable"` 的 reason 槽会让「只按
// reason 分支」的脚本把已确认的违规读成「没有结论」。

///|
/// NoWitness 的三种成因：键集合完全相同，只有 `cause` 的值不同。
test "LC-26: NoWitness 的 cause 三态共用同一张键表（形状 token 不变）" {
  for cause in ["data-inconsistency", "concurrency-race", "unknown"] {
    let out = no_witness_json(3, cause)
    assert_true(out.contains("\"reason\":\"no-explainable-witness\""))
    assert_true(out.contains("\"cause\":\"" + cause + "\""))
    assert_true(out.contains("\"witness\":[]"))
    assert_false(out.contains("\"depth\""))
  }
}

///|
/// 文本与 JSON 的成因必须逐条对应：同一个 cause 进两个渲染器，读出来的
/// 方向说明是同一支。
test "LC-26: 文本与 JSON 的成因逐条对应（同一份 cause）" {
  let n = 3
  // data-inconsistency：两个出口都指向「历史数据自相矛盾」
  let di = no_witness_json(n, "data-inconsistency")
  let di_text = @lib.no_explainable_witness_text_for(
    n,
    @lib.MIN_WITNESS,
    no_witness_cause(
      @lib.Violation({
        ops: [js_op(0, 0, @lib.Cas(1, 2), @lib.Bool(true), 2L, 5L)],
        depth: 0,
        explanation: "",
      }),
    ),
  )
  assert_true(di.contains("data-inconsistency"))
  assert_true(di_text.contains("历史数据自相矛盾"))
  // concurrency-race：两个出口都指向「并发竞态」
  let cr = no_witness_json(n, "concurrency-race")
  assert_true(cr.contains("concurrency-race"))
  assert_true(
    @lib.no_explainable_witness_text_for(
      n,
      @lib.MIN_WITNESS,
      "concurrency-race",
    ).contains("属于并发竞态"),
  )
  // unknown：JSON 的 cause 与文本的「成因未能确定」同源
  let unk = no_witness_json(n, no_witness_cause(@lib.Unknown("预算耗尽")))
  assert_true(unk.contains("\"cause\":\"unknown\""))
  assert_true(
    @lib.no_explainable_witness_text_for(
      n,
      @lib.MIN_WITNESS,
      no_witness_cause(@lib.Unknown("预算耗尽")),
    ).contains("成因未能确定"),
  )
}

///|
/// `no_witness_cause` 的三态：违规按 `violation_reason` 分类，其余一律
/// `unknown` —— 绝不兜底成 `concurrency-race`。
test "LC-26: no_witness_cause 不把 Unknown 编造成竞态" {
  let two = js_op(0, 0, @lib.Write(1), @lib.Ok, 0L, 5L)
  let racing = @lib.Violation::{ ops: [two], depth: 1, explanation: "", }
  assert_eq(no_witness_cause(@lib.Violation(racing)), "concurrency-race")
  let single = @lib.Violation::{ ops: [two], depth: 0, explanation: "", }
  assert_eq(no_witness_cause(@lib.Violation(single)), "data-inconsistency")
  assert_eq(no_witness_cause(@lib.Unknown("预算耗尽")), "unknown")
  assert_eq(no_witness_cause(@lib.Linearizable), "unknown")
}
