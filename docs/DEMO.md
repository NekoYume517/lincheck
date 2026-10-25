# 演示与复现

评审可以直接按顺序跑下面每一步。所有命令都在仓库根目录执行，不需要网络。

## 环境

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
moon version   # 期望 0.1.20261012 或更新
```

Windows：

```powershell
$env:MOON_HOME="$env:USERPROFILE\.moon"
$env:Path="$env:MOON_HOME\bin;"+$env:Path
moon version
```

## 一、clone 后立刻能跑

```bash
moon check
moon test      # 180 个测试
moon build --target wasm
```

预期：`Total tests: 180, passed: 180, failed: 0.`

## 二、看核心判定

```bash
# 合法历史
moon run cmd/lincheck -- check --history examples/register_ok.jsonl --model register
# → ✓ LINEARIZABLE  (3 个操作，模型 register)   exit 0

# 违规历史
moon run cmd/lincheck -- check --history examples/register_bad.jsonl --model register
# → ✗ NON-LINEARIZABLE  (3 / 3 个操作)          exit 1
```

这两份历史只差一个数字：

```
register_ok:   W=1 [0,10]   W=2 [5,15]    R→2 [20,30]     ✓
register_bad:  W=1 [0,10]   W=2 [12,20]   R→1 [30,40]     ✗
```

**`register_bad` 为什么违规**：两次写不重叠（`10 < 12`），所以 `W=2` 必然在 `W=1` 之后；`R` 在 30 开始，必然在两个写之后，必须读到 2，读到 1 就是违规。

**注意 `register_ok` 为什么不违规**：虽然只有两次写，但 `W=1 [0,10]` 和 `W=2 [5,15]` **重叠**（`5 < 10`），所以它们是并发的，可以按 `W=2 先、W=1 后` 排，然后 `R` 读到 2。这是最容易误判的情况。

## 三、看时间轴

```bash
moon run cmd/lincheck -- visualize --history examples/register_bad.jsonl
```

预期：

```
proc 0  |[W=1        ]                       [R->1       ]
proc 1  |              [W=2      ]
        +---------------------------------------------------> 时间  [0..40]


✗ 非线性一致（NON-LINEARIZABLE）
  见证子集：3 / 3 个操作
```

> **注意**：`visualize` 对违规历史返回退出码 `1`，这是正确行为——它把检查结果如实传递出来，不是程序出错。只有 `check` 的退出码应当作为判断依据。

## 四、最小反例

```bash
moon run cmd/lincheck -- minimize --history examples/noisy_bad.jsonl --model register
```

预期：

```
最小化：8 → 2 个操作
```

`noisy_bad.jsonl` 有 8 个操作，其中只有 2 个是真问题。最小化后保留的是「写先完成却读到旧值」这一对——这正是 bug 的本质，其余 6 个操作是噪声。

**为什么这个功能重要**：Jepsen 的报告动辄几千行，人能看懂的往往只有五行。自动压缩到最小反例，是让工具真正可用的关键。

## 五、最小化的设计约束（这是本项目的核心判断）

朴素 delta debugging 会这样压缩：

```
W=1, W=2, R→1
  ↓ 删掉 W=1
W=2, R→1         仍然违规（读到 1，只写过 2）
  ↓ 删掉 W=2
R→1              仍然违规（初值 0，读到 1 不可能）
```

最终得到单个 `R→1`。形式上仍是合法反例，但 **bug 的性质变了**：

- 原来是「读到**过期**值」——有并发、有覆盖，是真实的竞态
- 变成「读到**从没存在过**的值」——只需要检查初值就能发现，对调试毫无信息量

所以加了**可解释性约束**：若某操作单独看就违规，见证里必须存在一个同伴 `p` 使得 `{该操作, p}` 合法。判据只依赖 `Model` 和 `check`，四种模型通用。

`register_bad`（3 个操作）稳在 3→3：它已到最小见证下界，且删 `W=1` 后虽仍违规但会破坏 bug 语义（被可解释性守卫拦下），所以结语如实说明「无法继续缩减」；`noisy_bad`（8 个）能干净压到 2 且保留原 bug 语义——这个结果删任何一条都会变回线性一致（结语逐条复验后才这么声称）。

想对照纯 ddmin 的行为，可以看 `minimize_raw`。

## 六、元测试：验证检查器本身

这是最有说服力的一条：

```bash
moon run cmd/lincheck -- selfcheck --model register --seeds 300
```

预期：

```
selfcheck  model=register  seeds=300  ops/seed=4
  · 合法历史全部通过：是 ✓
    - 误判违规：0
    - 结论未知：0
  · 注入违规被发现：300 / 300
结果：PASS
```

**为什么这能证明检查器正确**：

`generate_consistent` 先在单一全序下顺序执行操作、记录结果，再随机拉宽时间区间——因为产物**构造上**就来自一个合法全序，所以它必然线性一致。

用它去测检查器：
- 若检查器报「违规」→ 假阳性，检查器有 bug
- 若检查器报「未知」→ 性能问题或剪枝有误

300 个合法历史全过、300 个注入违规全检出，说明剪枝没有漏掉合法顺序，也没有错误接受非法顺序。

四种模型都跑过：

```bash
for m in register counter set queue; do
  moon run cmd/lincheck -- selfcheck --model $m --seeds 30
done
```

## 七、生成自己的历史

```bash
moon run cmd/lincheck -- gen --model register --processes 3 --ops 10 --seed 42 --consistent
```

输出是 JSONL，可以直接喂给 `check`。同一个 seed 两次输出**字节级相同**（有 SHA256 比对测试）。

## 八、四种模型

```bash
# 单寄存器（内建示例都用它）
moon run cmd/lincheck -- check --history examples/register_ok.jsonl --model register

# 单调计数器 / 集合 / 队列
moon run cmd/lincheck -- check --history examples/register_ok.jsonl --model counter
moon run cmd/lincheck -- check --history examples/register_ok.jsonl --model set
moon run cmd/lincheck -- check --history examples/register_ok.jsonl --model queue
```

同一份历史换模型可能给出不同结论——这是正常的，因为「什么算合法」取决于对象的语义。

## 九、算法效率的直观证据

`register_bad` 只有 3 个操作，朴素全排列是 `3! = 6` 种顺序。WGL 只探索了 **3 个节点**：

1. `depth 0`：`min_end = 10`（W=1 的 end）→ 只有 `W=1` 是候选，`W=2` 的 `start=12 > 10` 被排除
2. `depth 1`：`min_end = 20` → 只有 `W=2`
3. `depth 2`：`min_end = 40` → `R` 可候选，但模型期望 `→ 2` ≠ 记录 `→ 1` → 剪枝

两次写不重叠这个事实直接把搜索树压成一条链。`explored=3` 这个数字写进了测试作为性能回归基线。

## 十、错误路径

```bash
moon run cmd/lincheck -- check --history nope.jsonl --model register
# → 数据错误：读不到文件：nope.jsonl        exit 4

moon run cmd/lincheck -- check --history examples/register_ok.jsonl --model bogus
# → 用法错误: 未知模型 bogus（可选 register, counter, set, queue)   exit 2
```

退出码：`0` 线性一致 / `1` 发现违规 / `2` 用法错误 / `3` 结论未知 / `4` 输入数据错误。

**`1` 和 `4` 必须分开**：

- `1` = 「历史确实非线性一致」，这是一个**有效结论**
- `4` = 「历史文件读不到或格式不对」，是**无法判断**

混用会让脚本把「数据有问题」误当成「发现 bug」——前者应该修数据，后者应该修系统，是完全不同的处理。

**`3`（未知）也是一个独立状态，不是错误。** 搜索是 NP 难的，大历史必然超预算。把「不知道」当成「线性一致」会漏报违规，当成「违规」会假警报，所以必须保留第三态。

**未知模型名不会静默回退。** 早期版本里 `--model bogus` 会回落到 register 模型并给出一个看起来权威的结论——拼错一个字母就换模型，这是最危险的一类缺陷。

## 十一、测试覆盖了哪些边界

| 文件 | 覆盖内容 |
|---|---|
| `src/history_test.mbt` | 并发判定、happens-before、JSONL 往返 |
| `src/model_test.mbt` | 四种模型的正反例 |
| `src/checker_test.mbt` | 暴力全排列交叉验证、缓存开关一致性、性能基线 |
| `src/minimize_test.mbt` | 可解释性约束、最小化后仍违规 |
| `src/generate_test.mbt` | 生成器确定性（SHA256 比对） |
| `src/visualize_test.mbt` | 时间轴渲染 |

`checker_test.mbt` 里有一个**暴力全排列参考实现**：对 n ≤ 6 的历史枚举全部排列，逐个子集判断是否存在合法顺序，再与 WGL 结论对比。覆盖 4 个 examples + 10 个手工边界情形（重叠读写、CAS 链、CAS 期望落空、写结果类型错误），全部一致。

## 十二、看到这里还没被说服？

`docs/algorithm.md` 记录了 7 个不显然的技术判断：

- 候选条件为什么用 `min(end)` 而不是 `min(start)`
- 缓存键为什么不能用哈希值（碰撞会**静默漏报违规**）
- 前缀和失败点为什么必须原子记录（否则解释文本方向会反）
- 最小化为什么必须有可解释性约束
- 生成器为什么能当元测试
- 超时为什么必须返回 `Unknown` 而不是猜
- `Int` 是 32 位，64 位位图为什么不能塞进一个 `Int`

每一条都对应一次真实的实现错误或一次险些踩进的陷阱。
