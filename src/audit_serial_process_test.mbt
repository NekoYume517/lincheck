// ============================================================================
// LC-6：单客户端（processes <= 1）生成的历史不得有同进程重叠区间
//
// 一个客户端一次只能有一个在途操作：它的第 k 条必须在上一条**返回之后**才开始。
// 生成器却只按「相邻操作」限制拉宽（第 3 步的 3a/3b），不看 process：
//
//     $ lincheck gen --model register --processes 1 --ops 6 --seed 1 --concurrency 1.0
//     {"id":0,...,"start":0,"end":4}      # 同 proc 0
//     {"id":1,...,"start":0,"end":6}      # 与上一条重叠 → 客户端同时有两个在途操作
//     {"id":2,...,"start":3,"end":9}
//
// 构造上的线性一致性不受影响（拉宽只动 end 往后 / start 往前，原全序仍成立），
// 但「合法历史」这个前提被削弱了：`selfcheck --processes 1`（以及被钳制到 1 的
// `--processes 0`）拿这种历史当「真实客户端的合法记录」，元测试的语义就不对了。
//
// 钳制规则保留：`--processes 0` → 1 是 2026-11-10 LC-A3 的显式契约
//（`docs/DEMO.md` 写明，`cli_exit_code_test.mbt` 锁着 exit 0），本次不动它；
// 要修的是「钳到 1 之后仍产出物理上不可能的历史」。
// ============================================================================

///|
/// 两条操作是否在时间上重叠（`a.end == b.start` 视为并发但不重叠）。
fn lc6_overlaps(a : Operation, b : Operation) -> Bool {
  a.end > b.start && b.end > a.start
}

///|
test "LC-6: 单客户端的历史必须串行（同进程无重叠）" {
  for
    cfg in [
      GenConfig::new(1, 6, 1, 1.0),
      GenConfig::new(1, 6, 7, 0.5),
      GenConfig::new(1, 12, 3, 1.0),
      // processes = 0 会被生成器钳制为 1，走同一条约束。
      GenConfig::new(0, 6, 3, 1.0),
      // 多客户端时同一进程相邻两次操作隔 step 条，约束同样必须成立。
      GenConfig::new(2, 6, 7, 1.0),
      GenConfig::new(3, 6, 42, 1.0),
      GenConfig::new(4, 5, 9, 1.0),
    ] {
    let h = generate_consistent(register_model(), cfg)
    assert_true(h.length() > 0)
    let ops = h.operations
    for i, a in ops {
      for j, b in ops {
        if i != j && a.process == b.process {
          assert_true(!lc6_overlaps(a, b))
        }
      }
    }
    // 串行不等于退化成「一条操作」：条数必须仍然等于 requests。
    assert_eq(
      h.length(),
      if cfg.processes < 1 {
        cfg.ops_per_process
      } else {
        cfg.processes * cfg.ops_per_process
      },
    )
  }
}

///|
/// 守护：多客户端时并发**必须仍然存在**——把拉宽一并关掉是另一种错误，
/// 会让「生成器能造出并发历史」这条前提消失（元测试也随之失效）。
test "LC-6 守护: 多客户端仍然能造出重叠区间" {
  let h = generate_consistent(register_model(), GenConfig::new(3, 8, 42, 1.0))
  let ops = h.operations
  let mut overlapping = 0
  for i, a in ops {
    for j, b in ops {
      if i != j && i < j && lc6_overlaps(a, b) {
        overlapping = overlapping + 1
      }
    }
  }
  assert_true(overlapping > 0)
  // 且这份历史仍然线性一致（拉宽不许破坏原全序）。
  assert_true(
    check_with(h, register_model(), CheckConfig::default()) is Linearizable,
  )
}
