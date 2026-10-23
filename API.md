# lincheck — API 契约

> **这是实现依据，不得更改签名。** 内部实现自由，但这些公开 API 必须存在且签名一致。

模块名：`moonbit-hack/lincheck`，库包：`src`，CLI 包：`cmd/lincheck`。

## 1. 历史模型 `src/history.mbt`

```moonbit
pub type OpId = Int32

pub(all) enum OpKind {
  Write(Int32)      // 写入值
  Read              // 读取
  Cas(expected : Int32, new : Int32)
  Append(Int32)     // 队列/日志追加
  Pop               // 队列弹出
} derive(Eq, Debug)

pub(all) enum OpResult {
  Ok                       // 写成功
  Value(Int32)             // 读到的值
  Bool(Bool)               // CAS 成功与否
  Empty                    // Pop 时队列为空
  Nil                      // 超时/未知
} derive(Eq, Debug)

pub(all) struct Operation {
  id : OpId
  process : Int32
  kind : OpKind
  result : OpResult
  start : Int64        // 逻辑时间戳（调用发生）
  end : Int64          // 逻辑时间戳（响应发生）
} derive(Debug)

pub(all) struct History {
  operations : Array[Operation]
}

pub fn History::new() -> History
pub fn History::add(self : History, op : Operation) -> Unit
pub fn History::length(self : History) -> Int32
pub fn History::sort_by_start(self : History) -> History

/// A 在 B 之前完成（且不重叠）
pub fn happens_before(a : Operation, b : Operation) -> Bool

/// 两个操作是否并发（区间重叠）
pub fn concurrent(a : Operation, b : Operation) -> Bool

/// JSONL 序列化
pub fn History::to_jsonl(self : History) -> String
pub fn History::from_jsonl(text : StringView) -> Result[History, HistoryError] raise

/// 排序用的全序比较：先 start 再 id（显式三分支，不做减法——
/// start 是完整 Int64、id 是完整 Int32，减法在极值处会溢出并破坏全序）
pub fn compare_ops(a : Operation, b : Operation) -> Int32
pub fn compare_ops_by_id(a : Operation, b : Operation) -> Int32

pub(all) suberror HistoryError {
  BadLine(line_no : Int32, reason : String)
} derive(Eq, Debug)
```

JSONL 每行（**字段名固定**）：

```json
{"id":0,"process":0,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":0,"end":10}
```

`start` 和 `end` 在完整 Int64 范围内精确解析，包含超过 2^53 的时间戳；
小数、科学计数法仅在其十进制精确值为范围内整数时接受。`id`、`process`
和操作参数同样必须是精确 Int32，不能通过浮点舍入变成整数。
解析器保留原始数字文本：先由 core/json 验证，再解析一份数字 token 被引用
为字符串的同结构树，为原 Number 补齐原文。字符串、转义键和重复键遵循
core/json 语义。这需要每行两次 JSON 解析，换取十进制和指数形式的精确性。

## 2. 抽象对象模型 `src/model.mbt`

```moonbit
pub trait Model {
  /// 模型名
  name(Self) -> String
  /// 初始状态
  init(Self) -> State
  /// 应用操作，返回 (新状态, 期望的返回值)
  /// 如果该操作在此状态下非法，返回 None
  apply(Self, State, OpKind) -> (State, OpResult)?
  /// 校验已知实际结果；默认比较 expected/actual（模型显式 Nil 期望为通配）。
  /// 非确定模型应覆写并限制合法结果集。state 为操作执行前的状态。
  accepts(Self, State, OpKind, OpResult, OpResult) -> Bool = _
  /// 状态相等（用于缓存）
  state_eq(Self, State, State) -> Bool
  /// 状态哈希（用于缓存）
  state_hash(Self, State) -> Int
}

/// 状态是整数向量的统一表示（够用且高效）
pub type State = Array[Int]

/// 内建模型
pub fn register_model() -> Model          // 单寄存器：Write/Read/Cas
pub fn counter_model() -> Model           // 单调计数器：Increment/Read
pub fn set_model() -> Model               // 集合：Add/Contains/Remove
pub fn queue_model() -> Model             // 队列：Append/Pop
```

`State` 用 `Array[Int]` 而不是泛型，是为了让哈希缓存高效且实现简单。各模型约定：

- **register**：`State = [value]`。Write(v) → `[v]`，期望 Ok；Read → `[v]`，期望 Value(v)；Cas(e,n) → 若 v==e 则 `[n]` 期望 Bool(true)，否则 `[]` 期望 Bool(false)（状态不变）。
- **counter**：`State = [value]`。只增不减。
- **set**：`State = [低32位掩码, 高32位掩码]`（限制值域 0..63）。Write/Append 插入，Pop 删除最小成员并返回 Bool；Read 可返回任一当前成员 `Value(v)`，空集返回 `Value(-1)`。`apply` 提供最小成员作为生成器用的合法代表结果，`accepts` 校验实际返回的成员资格。
- **queue**：`State = [元素编码为定长序列]`。

## 3. 核心检查器 `src/checker.mbt`

Wing-Gong-Lowe 算法 + Lowe 的状态缓存。

```moonbit
pub(all) enum CheckOutcome {
  /// 线性一致
  Linearizable
  /// 发现反例
  Violation(Violation)
  /// 响应证据不完整、区间非法或超时，结论未知
  Unknown(reason : String)
} derive(Debug)

pub(all) struct Violation {
  /// 反例的操作子集（按 id 升序）：最长一致前缀 + 被卡住的操作。
  /// 被卡住的操作可能是「返回值不匹配」也可能是「模型拒绝执行」
  /// （例如单调计数器的回退）——两种都进证据，check(ops) 必然再次
  /// 报告违规。
  ops : Array<Operation>
  /// 搜索过程中最后一致的前缀长度
  depth : Int32
  /// 人类可读的解释
  explanation : String
}

pub(all) struct CheckConfig {
  time_budget_ms : Int32       // 默认 5000
  max_states : Int32           // 缓存上限，默认 200_000
  /// 是否把历史记录中的 Nil 结果视为"可以返回任意值"（宽松模式）。
  /// 默认 false：出现实际 Nil 时返回 Unknown，并报告未知结果数量。
  /// true 显式假设未知响应可匹配模型；它不支持 pending 操作的可选完成语义。
  /// 已知结果通过 Model::accepts
  /// 校验；默认实现允许模型显式 Nil 期望作为通配，集合模型不用该通配。
  allow_unknown_results : Bool
}

pub fn CheckConfig::default() -> CheckConfig

pub fn check(history : History, model : Model, config : CheckConfig) -> CheckOutcome
pub fn check_default(history : History, model : Model) -> CheckOutcome
```

**算法要求**（必须严格按此实现）：

```
状态：linearized = 已完成的操作集合，current = 当前状态
候选：所有 op 满足
        op 未完成
        且 op.start <= 所有"未完成且未开始线性化"操作的 min(end)
      即：op 不能排在某个已经完成的并发操作之后

对每个候选 op（按 start 排序保证确定性）:
    match model.apply(current, op.kind):
        Some((next, expected)) if model.accepts(current, op.kind, expected, op.result) ->
            递归(next, linearized + op, ...)
            若成功 return Linearizable
        _ -> 剪枝（该候选不可能）

缓存键：(current 哈希, 剩余操作 id 集合的哈希)
        命中 (状态,剩余) -> 已知结果，直接返回
```

**关键正确性约束**：
- 候选选择必须用 `op.start <= min(end of 所有未线性的操作)`。
- 剪枝后必须能记录**最深的一致前缀**，用于生成可读反例。
- 缓存命中时不得改变语义（只缓存"确定失败"或"确定成功"）。

## 4. 最小化反例 `src/minimize.mbt`

```moonbit
/// 对违规历史做 delta-debugging，得到最小子集
pub fn minimize(history : History, model : Model, config : CheckConfig) -> Violation

/// 按进程分组的最小化（常能显著缩小）
pub fn minimize_by_process(history : History, model : Model) -> Violation

/// 同上，可空入口：None = 历史违规，但不存在满足下界与可解释性的见证
pub fn minimize_witness(history : History, model : AnyModel, config : CheckConfig) -> Violation?
pub fn[M : Model] minimal_witness(
  seed : Array[Operation],
  pool : Array[Operation],
  model : M,
  config : CheckConfig,
  min_witness : Int32,
  expl : Expl,
) -> Array[Operation]?
```

要求：最小化后仍必须违规（用 `check` 验证），且操作数尽量少。

**最终返回值的三重约束**（`witness_ok`，缺一不可）：

1. `ops.length() >= min_witness`（默认 `MIN_WITNESS = 2`）
2. `check_with(ops)` 仍是 `Violation`
3. `explainable(ops, ...)`：每个「孤立非法」的操作都有同伴解释它的来源

三条约束对**返回的数组本身**生效，而不只是对中途的候选删除生效：
`check` 给出的种子本身可能只有一条操作（例如初值 0 上记录
`Cas(1->2) -> Bool(true)`，属于历史数据自相矛盾），此时最小化会改在整份
历史里重新找合格见证。确实找不到时，`minimal_witness` / `minimize_witness`
返回 `None`，`minimize` 原样返回整份历史并用
`no_explainable_witness_text(total, min_witness)` 说明原因——不输出退化解，
也不 panic。CLI 在 `--json` 下把它标记为
`{"verdict":"non-linearizable","witness":[],"reason":"no-explainable-witness"}`，
退出码仍为 `1`（历史确实违规是一个有效结论）。

`minimize_raw` 是显式的不设防入口（`min_witness = 0`），允许压到单条操作，
仅供对照与教学使用。

## 5. 历史生成 `src/generate.mbt`

用于元测试：自动生成并发历史。

```moonbit
pub(all) struct GenConfig {
  processes : Int
  ops_per_process : Int32
  seed : Int
  /// 并发度：0 = 全串行，1 = 完全随机并发
  concurrency : Double
}

/// 生成一个"保证线性一致"的历史：先在单一全序下执行，再随机拉宽时间区间
pub fn generate_consistent(model : Model, config : GenConfig) -> History

/// 生成随机历史（可能是非线性的，用于测试检查器能发现问题）
pub fn generate_random(model : Model, config : GenConfig) -> History

/// 在合法历史里注入一个错误，制造确定的违规
pub fn inject_violation(history : History, model : Model, seed : Int) -> History
```

要求：生成器必须**确定性**（同一 seed 输出完全相同）。

## 6. 可视化 `src/visualize.mbt`

```moonbit
/// 文本时间轴：每行一个进程，操作画成横条
pub fn render_timeline(history : History) -> String

/// 渲染反例，高亮冲突操作
pub fn render_violation(v : Violation, history : History) -> String
```

`render_timeline` 输出示例（**必须类似**）：

```
proc 0  |[W=1     ]          [R->1  ]
proc 1  |      [W=2      ]
proc 2  |                    [R->2   ]
        +------------------------------> 时间
```

## 7. CLI `cmd/lincheck/main.mbt`

```
lincheck check     --history <file.jsonl> --model register|counter|set|queue [--budget-ms N] [--json]
lincheck minimize  --history <file.jsonl> --model register
lincheck visualize --history <file.jsonl>
lincheck gen       --model register --processes 3 --ops 10 --seed 42 --consistent
lincheck selfcheck --model register --seeds 100        # 元测试：生成的合法历史必须通过
```

退出码：0 线性一致，1 发现违规，2 用法错误，3 未知。

## 8. 测试要求

- **手工小例子**：3-5 个手写历史，人工已知答案
- **元测试**：`generate_consistent` 生成 200 个历史，`check` 必须全部 `Linearizable`
- **注入测试**：`inject_violation` 后必须 `Violation`
- **缓存正确性**：开/关缓存结果必须一致
- **最小化**：最小化结果仍违规，且操作数 ≤ 原历史
- **确定性**：同一输入两次运行输出相同
- **未知证据与超时**：严格模式的实际 Nil、非法时间区间及搜索超时返回 `Unknown`，不能据此报告并发违规。
