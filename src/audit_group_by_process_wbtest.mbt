// ============================================================================
// LC-24：按进程分组必须是**一次遍历**，且输出与旧实现逐字节相同
//
// 2026-11-21 审计：`render_ops` / `process_ids` / `minimize_by_process` 都用
// `for p in procs { for op in ops { ... } }` 做分组，等价于 O(操作数 × 进程数)。
// `gen --processes 100000 --ops 1` 是**合法**参数（总操作数 1e5），
// 1e5 × 1e5 = 1e10 次比较：改前 `visualize` 在 100001 行历史上 45.2 s，改后
// 5.2 s（证据 `audit/2026-11-21/lincheck/evidence/02-render-timing.log`、
// `02-render-before-after.log`）。
//
// 复杂度没法在测试里断言（那会把机器速度写进断言，LC-13 的教训），所以这里锁
// 的是**语义**：一次遍历装桶之后，
//   1. 进程号升序且唯一（与旧实现 `procs.sort()` 相同的次序）；
//   2. 每个桶里正好是这个进程的操作，且保持**原始出现顺序**；
//   3. 渲染结果的行序 = 进程号升序，行数与进程数相同；
//   4. 渲染**不许重排历史本身**（桶是新数组，就地排序不能穿透到 history）。
// 逐字节一致性另由 CLI 前后的 `cmp` 证据承担。
// ============================================================================

///|
fn grp_op(
  id : Int32,
  process : Int32,
  start : Int64,
  stop : Int64,
) -> Operation {
  Operation::{ id, process, kind: Read, result: Value(0), start, end: stop, }
}

///|
test "LC-24: 装桶保持原始出现顺序、进程号升序唯一" {
  // 乱序的进程号 + 重复：5, -3, 5, 7, -3
  let ops = [
    grp_op(0, 5, 0L, 1L),
    grp_op(1, -3, 2L, 3L),
    grp_op(2, 5, 4L, 5L),
    grp_op(3, 7, 6L, 7L),
    grp_op(4, -3, 8L, 9L),
  ]
  let (procs, groups) = group_by_process(ops)
  // 1. 升序、唯一
  assert_eq(procs, [-3, 5, 7])
  assert_eq(groups.length(), procs.length())
  // 2. 桶内是「这个进程的操作」且保持出现顺序（id 0 在 id 2 前面）
  assert_eq(groups[0].length(), 2)
  assert_eq(groups[0][0].id, 1)
  assert_eq(groups[0][1].id, 4)
  assert_eq(groups[1].length(), 2)
  assert_eq(groups[1][0].id, 0)
  assert_eq(groups[1][1].id, 2)
  assert_eq(groups[2].length(), 1)
  assert_eq(groups[2][0].id, 3)
  // 元素总数不变
  let mut total = 0
  for g in groups {
    total = total + g.length()
  }
  assert_eq(total, ops.length())
}

///|
test "LC-24: 空历史装桶是空的（不崩、不产生幽灵行）" {
  let (procs, groups) = group_by_process([])
  assert_eq(procs.length(), 0)
  assert_eq(groups.length(), 0)
}

///|
test "LC-24: 300 个进程的渲染行序 = 进程号升序，行数 = 进程数" {
  let ops : Array[Operation] = []
  let mut i = 0
  while i < 300 {
    ops.push(grp_op(i, i, i.to_int64() * 10L, i.to_int64() * 10L + 5L))
    i = i + 1
  }
  let h = History::{ operations: ops, }
  // 进程号升序、唯一
  let ids = process_ids(h)
  assert_eq(ids.length(), 300)
  let mut k = 0
  while k < 300 {
    assert_eq(ids[k], k)
    k = k + 1
  }
  let text = render_timeline(h)
  // 行数 = 300 个进程行 + 1 条时间轴
  let mut lines = 0
  for ch in text {
    if ch == '\n' {
      lines = lines + 1
    }
  }
  assert_eq(lines, 301)
  // 行序 = 进程号升序：'proc 0' 在 'proc 299' 之前，且没有 'proc 300'
  assert_true(text.contains("proc 0  "))
  assert_true(text.contains("proc 299"))
  assert_false(text.contains("proc 300"))
}

///|
test "LC-24: 渲染不许重排历史本身" {
  // 进程 1 的操作在前、进程 0 的在后：渲染后 history 的顺序必须原样。
  let ops = [grp_op(0, 1, 0L, 1L), grp_op(1, 0, 2L, 3L), grp_op(2, 1, 4L, 5L)]
  let h = History::{ operations: ops, }
  let _ = render_timeline(h)
  assert_eq(h.operations[0].id, 0)
  assert_eq(h.operations[1].id, 1)
  assert_eq(h.operations[2].id, 2)
  assert_eq(h.operations[0].process, 1)
  assert_eq(h.operations[1].process, 0)
}
