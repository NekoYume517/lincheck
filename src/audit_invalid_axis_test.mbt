// ============================================================================
// LC-3：`visualize` 不得为非法时间区间画出反向时间轴
//
// 现象（2026-11-17 审计 LC-3，实测）：
//
//     $ cat bad_interval.jsonl      # {"id":0,...,"start":100,"end":0}
//     $ lincheck visualize --history bad_interval.jsonl
//     proc 0  |[R->0]
//             +--------> 时间  [100..0]
//
//     ? 结论未知：操作 0 的时间区间非法：start=100 > end=0        exit 3
//
// 退出码与结语都对（`start > end` = 「文件读得懂但无法判定」→ 3，见
// `docs/exit-codes.md`），但同一段输出里画了一条从 100 回到 0 的时间轴：
// 数字全对、只有人眼能看出画反了 —— 与上一轮 LC-D2（列号 Int64 回绕）
// 同族的「诊断输出自相矛盾」。
//
// 判据：`render_ops` 在发现任何 `start > end` 时**不画时间轴**，改为明确说明
// 「区间非法，时间轴不成立」。退出码不动（仍由 check 的 Unknown 决定）。
// ============================================================================

///|
fn lc3_invalid_history() -> History {
  History::{
    operations: [
      Operation::{
        id: 0,
        process: 0,
        kind: Read,
        result: Value(0),
        start: 100L,
        end: 0L,
      },
    ],
  }
}

///|
/// 一份合法历史（`examples/register_bad.jsonl` 同款），用于守护「没坏的东西
/// 不许动」：它的渲染仍必须是一张正常时间轴。
fn lc3_valid_history() -> History {
  History::{
    operations: [
      Operation::{
        id: 0,
        process: 0,
        kind: Write(1),
        result: Ok,
        start: 0L,
        end: 10L,
      },
      Operation::{
        id: 1,
        process: 1,
        kind: Write(2),
        result: Ok,
        start: 12L,
        end: 20L,
      },
      Operation::{
        id: 2,
        process: 0,
        kind: Read,
        result: Value(1),
        start: 30L,
        end: 40L,
      },
    ],
  }
}

///|
test "LC-3: 非法区间不得画出反向时间轴" {
  let out = render_timeline(lc3_invalid_history())
  // 不许出现倒序区间标签，也不许出现任何画出来的横条。
  assert_true(!out.contains("100..0"))
  assert_true(!out.contains("[R->0]"))
  // 必须明确说明为什么没有图，而不是静默省略。
  assert_true(out.contains("区间非法"))
}

///|
/// 守护：合法历史的时间轴一个字符都不许变（上一次审计的粘贴输出仍要成立）。
test "LC-3 守护: 合法历史的时间轴照旧" {
  let out = render_timeline(lc3_valid_history())
  assert_true(out.contains("[0..40]"))
  assert_true(out.contains("[W=1"))
  assert_true(out.contains("[W=2"))
  assert_true(out.contains("[R->1"))
  assert_true(!out.contains("区间非法"))
}
