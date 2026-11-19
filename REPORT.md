# lincheck 缺陷审计报告（2026-11-20）

## 结论

- 基线：`moon info && moon build && moon test --target all` 全绿，native / JS 各 **281/281**；工作树干净。
- 经 lead 批准的 10 项攻击面中，确认并修复 **3 类可复现缺陷**，形成 **4 个修复提交**（LC-20 的长、短选项边界分两次补全）。
- 新增 **4 个确定性回归测试**。最终 native / JS 各 **285/285**；`moon check`、`moon fmt --check`、`moon build --target wasm` 均通过。
- 没有新增依赖机器速度或长时间忙等的测试；没有 push。
- 证据目录（仓库外）：`D:\code\moonbit\audit\2026-11-20\lincheck`。

## 修复提交

| 提交 | 类型 | 摘要 |
| --- | --- | --- |
| `27cda04` | `fix(cli)` | 未知长选项不得被 `--history` 吞成路径 |
| `db3b4dd` | `fix(cli)` | 已知/未知短选项在 `--history` 值位同样归类为用法错误 |
| `11d5a88` | `fix(visualize)` | 有序对按下标去重，完全重复操作仍计入扫描进度 |
| `74fda59` | `fix(cli)` | 带前导零的 Int32 最小值正确解析 |

## 缺陷与复现

### 1. `--history` 把选项误吞为路径，退出码从 2 错成 4

**位置**：`cmd/lincheck/main.mbt` 的 `parse_from`。

**修复前红测试**：

```sh
moon test --target native -p NekoYume517/lincheck/cmd/lincheck
```

`check / minimize / visualize --history --not-a-real-option` 均得到 `4`，预期为用法错误 `2`。第一版只泛化到 `--` 后，补查又确认 `--history -h` 与 `--history -x` 得到 `4`；这也覆盖了短选项边界。

**修复**：

- 所有带值参数把后续 `--...` 视为缺值，而不是只挡已知 flag。
- `--history` 对 `-...` 也按选项处理；数值参数的负值仍进入各自解析器，保留“不能为负”的领域诊断。
- 真正以 `-` 开头的路径通过 `./-name` 显式指定；回归使用 `_build` 内的合法历史验证 `./` 路径仍退出 0。

**证据**：

- `lc20-unknown-option-red.log`
- `lc20-short-option-red.log`
- `lc20-unknown-option-focused-green.log`
- `lc20-short-option-focused-green.log`
- `lc20-test-all.log`、`lc20-short-test-all.log`

### 2. 完全重复操作使 `order_facts` 扫描计数与分母失真

**位置**：`src/visualize.mbt` 的 `order_facts`。

**修复前红测试**：

```sh
moon test --target native -p NekoYume517/lincheck
```

构造 143 个完全相同的 `Operation`。数学上有 `143 × 142 = 20306` 个有序对，应触发 20000 对扫描上界；旧代码用 `a != b` 按值排除所有组合，直接返回空字符串，连截断摘要都消失。

**修复**：仅按下标 `i != j` 排除自比较。完全相同的两个操作虽然不成立 `end < start`，仍属于 `n(n-1)` 分母和扫描进度。回归同时核对 `found=0`、`shown=0` 和独立总数口径。

**证据**：

- `lc10-duplicate-pairs-red.log`
- `lc10-duplicate-pairs-focused-green.log`
- `lc10-duplicates-test-all.log`

### 3. 带前导零的 Int32 最小值被误判溢出

**位置**：`cmd/lincheck/main.mbt` 的 `parse_int_arg`。

**修复前红测试**：

```sh
moon test --target native -p NekoYume517/lincheck/cmd/lincheck \
  -f 'parse_int_arg 接受带前导零的 Int32 最小值'
```

`parse_int_arg("-0002147483648")` 返回 `None`，预期 `Some(-2147483648)`。旧特判只识别原始字符串 `-2147483648`，前导零使其进入正数累加器并被误判溢出。

**修复**：在溢出判断前去掉多余前导零（至少保留一位），再执行 Int32 最小值特判。`-0002147483649` 仍返回 `None`，没有放宽真正越界值。

**证据**：

- `int32-leading-zero-red.log`
- `int32-leading-zero-focused-green.log`
- `int32-leading-zero-test-all.log`

## 10 项攻击面复盘

| 项 | 结果 |
| --- | --- |
| 1. CLI 缺值同族入口 | 已修复长、短选项误吞；`./` 真实路径守护通过。 |
| 2. Unknown 跨命令一致性 | 现有非法区间、Nil、超时专项回归全绿；未把未知改写成确定结论。 |
| 3. minimize 探针 Unknown | 当前 `minimal_witness_trace` 与 `ddmin_trace` 均透传 Unknown 并进入结语；现有 raw / standard / process 回归全绿，无新增实锤。 |
| 4. 缓存与重复操作 | 缓存只写 Linearizable/Violation，不写 Unknown；现有重复 id、缓存档位与 pair Unknown 回归全绿。 |
| 5. JSON 形状 | linearizable / violation / unknown / no-witness 专项回归全绿；NoWitness 继续保持无 `depth` 的既定契约。 |
| 6. 参数域 | 修复 Int32 最小值前导零；其余 0、负值、乘法上限与小数回归全绿。 |
| 7. 预算边界 | 0=无限、负值拒绝、缓存命中轮询等现有回归全绿；未新增时间敏感断言。 |
| 8. Int64 时间与渲染 | 现有 Int64 极值、2^53 邻值、同刻、零跨度与 JSONL 往返回归全绿，无新增实锤。 |
| 9. visualize 计数 | 修复完全重复操作的扫描计数；截断输出和实际时间约束总数恢复同口径。 |
| 10. 生成与 selfcheck | 四模型 selfcheck、生成总数钳制、注入违规与缓存开关回归全绿；`generate_consistent` 同进程区间承诺未见反例。 |

## 修改文件

- `cmd/lincheck/main.mbt`
- `cmd/lincheck/cli_history_option_boundary_wbtest.mbt`（新增）
- `cmd/lincheck/cli_int_leading_zero_wbtest.mbt`（新增）
- `src/visualize.mbt`
- `src/audit_order_facts_duplicates_wbtest.mbt`（新增）
- `REPORT.md`（本报告）

## 最终验证

每个修复提交前均执行并通过：

```sh
moon check
moon fmt --check
moon test --target all
moon build --target wasm
git diff --check
```

最终测试：native **285/285**，JS **285/285**。编译器保留项目原有 warning，无 error；没有为清理既有 warning 混入无关改动。
