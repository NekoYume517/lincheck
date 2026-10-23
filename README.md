# lincheck

**线性一致性检查器：判断一段并发历史是否合法，并在违规时给出最小反例。**

[![MoonBit](https://img.shields.io/badge/MoonBit-0.1.20261012-blueviolet)](https://www.moonbitlang.com/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

---

## 问题

两个线程同时操作一个变量：

```
线程 A:  x = 1        [  0 ── 10  ]
线程 B:  x = 2        [      5 ── 15 ]
线程 A:  print(x)     [             20 ── 30 ]
```

A 最后打印出 `2`，合理——B 的写在 A 的读之前就完成了。

如果打印出 `1` 呢？**不可能**。B 的写（5–15）在 A 的读（20–30）之前结束，没有任何"瞬间"能让 A 读到旧值。

**线性一致性（linearizability）** 就是这个直觉的形式化：

> 存在一个全序，使得每个操作在它"开始到结束之间"的某一点原子生效，且该全序下的结果符合对象的顺序语义。

通俗说：**虽然操作是并发的，但你必须能把它排成一个队，让每个操作看起来在某个瞬间原子地完成。**

这是并发对象的黄金标准，比顺序一致性更强（它尊重真实时间），也是所有分布式数据库承诺的隔离级别。

## 为什么需要工具

2013 年起，Kyle Kingsbury 的 **Jepsen** 给数据库注入网络分区、时钟偏移、进程暂停，然后检查它们是否真的满足自己宣称的一致性。结果：MongoDB、Cassandra、etcd、Redis（Redlock）、RabbitMQ、Elasticsearch……几乎每个主流系统都被找到过真实的数据丢失。

手工检查不现实。100 个操作有天文数字种可能的排序——需要算法。

## 快速开始

```bash
moon check
moon test

# 检查一份历史
moon run cmd/lincheck -- check --history examples/register_ok.jsonl --model register

# 看时间轴
moon run cmd/lincheck -- visualize --history examples/register_bad.jsonl

# 自检：生成的合法历史必须全部通过
moon run cmd/lincheck -- selfcheck --model register --seeds 100
```


## 命令

```bash
lincheck check     --history <file.jsonl> --model register|counter|set|queue [--budget-ms N] [--json]
lincheck minimize  --history <file.jsonl> --model register
lincheck visualize --history <file.jsonl>
lincheck gen       --model register --processes 3 --ops 10 --seed 42 --consistent
lincheck selfcheck --model register --seeds 100
```

退出码：`0` 线性一致 / `1` 发现违规 / `2` 用法错误 / `3` 结论未知 / `4` 输入数据错误。

> **为什么 `1` 和 `4` 要分开**：`1` 的意思是「历史确实非线性一致」，这是一个
> **有效结论**；`4` 的意思是「历史文件读不到或格式不对」，是**无法判断**。
> 混用会让脚本把「数据有问题」误当成「发现 bug」。

> **注意**：`visualize`、`minimize` 也会按检查结果返回退出码。对
> `examples/register_bad.jsonl` 这类**故意构造的违规历史**，它们返回 `1` 是
> 正确行为，不是程序出错——`1` 的意思就是「这份历史确实非线性一致」。
> 只有 `check` 的退出码应该被当作判断依据；`visualize`/`minimize` 返回 `1`
> 只是把它检查到的事实如实传递出来。

> **退出码 `1` 内部还有一层区分**：真并发竞态
> （`"reason":"concurrency-race"`）vs 历史数据自相矛盾
> （`"reason":"data-inconsistency"`）。后者是「见证只有一条操作，且它相对
> **初始状态**就不可能成立」，例如初值 0 的寄存器上记录了
> `Cas(1->2) -> true`——没有并发交错能解释它，该去查历史/初值，而不是查
> 数据结构的竞态。人类可读解释里会直接写明「不是并发竞态」，细节见
> [docs/exit-codes.md](docs/exit-codes.md)。

## 历史格式

每行一个操作：

```json
{"id":0,"process":0,"kind":{"tag":"Write","value":1},"result":{"tag":"Ok"},"start":0,"end":10}
```

`start`/`end` 是逻辑时间戳（同一时钟），区间重叠即视为并发。

## 算法：Wing-Gong-Lowe

检查"是否存在合法全序"是 NP 难的，但实际历史可以秒出结果。

**基本搜索**：

```
已线性化 = {}
当前状态 = 初始状态

每步:
    候选 = 所有满足条件的未完成操作:
           它的 start ≤ 所有"尚未线性化"操作的最小 end
    对每个候选（按 start 排序保证确定性）:
        若 apply(当前状态, op) 的期望返回值 == op.result:
            递归(下一状态, 已线性化 ∪ {op})
        否则剪枝
```

以开头的例子验证：`x=1[0,10]`、`x=2[5,15]`、`read→1[20,30]`

- 初始两个写都可作候选
- 试 `x=1` → 状态 `{x:1}` → 试 `x=2` → 状态 `{x:2}` → 读到 2 ≠ 1，剪枝
- 回溯，先试 `x=2` → 状态 `{x:2}` → 再试 `x=1` → 状态 `{x:1}` → 读到 1 ✓
- 但 `x=2.end=15 < read.start=20`，read 必须排在 x=2 之后，这个约束自然排除了该顺序
- 所有分支走完 → **判定非线性一致**

**关键优化（Lowe 2017）**：缓存 `(当前状态, 剩余操作集合) → 结果`，键是
**精确编码**（状态字面量 + 剩余集合位串），不是哈希——哈希碰撞会让搜索把
没探过的子问题当成已失败，静默漏报违规。没有缓存复杂度是操作数的阶乘；
有了它，上百个操作的实际历史通常一秒内出结果。

## 最小反例

Jepsen 的报告动辄几千行，人能看懂的往往只有五行。`lincheck` 在发现违规后做 **delta debugging**：反复尝试删掉操作，只要仍然违规就保留删除，最终得到最小子集。

实际输出（`examples/register_bad.jsonl`）：

```
✗ NON-LINEARIZABLE  (2 / 2 个操作)

  proc 0  W=1  ->  Ok  [0..10]
  proc 1  W=2  ->  Ok  [12..20]

  非线性一致（模型 register）：最多可线性化 1 / 2 个操作，之后无路可走。
  ……（完整解释含最长一致前缀与被迫顺序）
```

## 设计要点

**状态用整数向量。** `State = Array[Int]` 而不是泛型，让哈希缓存高效、实现简单。每个模型约定自己的编码。

**确定性优先。** 候选按 `start` 排序、哈希用固定算法、生成器用固定种子。同一输入两次运行必须输出完全相同——否则 bug 无法复现。

**未知是合法结论。** 搜索超预算、时间区间非法或默认严格模式下含 `Nil`（未知响应）时返回 `Unknown`。缺失响应不能证明并发违规；CLI 的 `check`、`minimize`、`visualize` 都以退出码 `3` 表示未知，JSON 判定为 `unknown`。库调用方可显式启用 `allow_unknown_results=true`，乐观假设这些响应匹配模型；该选项仍按记录的区间执行每个操作，并未实现 pending 操作的可选完成语义。

**生成器服务于元测试——但要清楚它验证到哪一层。** `generate_consistent`
先在单一全序下执行、再随机拉宽时间区间，产物构造上就来自一个合法全序。
`selfcheck` 用它验证两件事：合法历史**不会被误判为违规**（假阳性），以及
注入的违规**总能被检出**（对已知坏样本的灵敏度）。它**不能**证明"所有真
违规都能检出"——注入是按确定性规则改写产物，注入后用同一个 check 复检
通过是构造使然，这部分不构成独立证据。检查器与暴力全排列参考实现的交叉
验证（`checker_test.mbt`，n≤6 全排列）补上了这一层。

## 项目结构

```
src/
  history.mbt      Operation / History / 并发判定 / JSONL
  model.mbt        Model trait / State / 内建模型
  checker.mbt      WGL 搜索 + 状态缓存
  minimize.mbt     delta debugging 最小化
  generate.mbt     历史生成与故障注入
  visualize.mbt    文本时间轴
cmd/lincheck/
  main.mbt         CLI
```

详细 API 见 [API.md](API.md)。

## 背景资料

- M. P. Herlihy, J. M. Wing, *Linearizability: A Correctness Condition for Concurrent Objects*, TOPLAS 1990
- J. M. Wing, C. Gong, *Testing and Verifying Concurrent Objects*, 1993
- G. Lowe, *Testing for Linearizability*, Concurrency and Computation 2017
- K. Kingsbury, *Jepsen* — https://jepsen.io

## License

Apache-2.0，见 [LICENSE](LICENSE)。



