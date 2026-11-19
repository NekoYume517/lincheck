///| LC-10 同族入口：去重有序对的“去重”单位是数组下标，不是操作值。
///
/// 完全相同的 Operation 可以占据两个历史位置；它们之间虽然不成立
/// `end < start`，仍属于摘要分母 n(n-1) 中的一对。按 `a != b` 跳过会把
/// 这些位置从扫描进度里抹掉，甚至让超过 scan_limit 的历史不再出现截断说明。

///|
test "order_facts 完全重复操作仍计入扫描对数" {
  let op = Operation::{
    id: 7,
    process: 0,
    kind: Read,
    result: Value(0),
    start: 0L,
    end: 1L,
  }
  let ops : Array[Operation] = []
  for _ in 0..<143 {
    ops.push(op)
  }
  let text = order_facts(ops)
  // 143 * 142 = 20306，已经超过 20000 的扫描上界。
  assert_true(text.contains("共 20306 对有向组合；已扫描 20000 对"))
  assert_true(text.contains("其中 0 条时间约束成立"))
  assert_true(text.contains("该子集实际共有 0 条时间约束"))
}
