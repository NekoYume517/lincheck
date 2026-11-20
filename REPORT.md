# lincheck 缺陷审计报告（2026-11-21）

> 历史轮次见 `git log` 与 `audit/2026-11-19`、`audit/2026-11-20`、`audit/2026-11-21`；
> 本文件只记当前轮，正文不含旧内容。

## 结论

- 基线 `da342b1` 全绿（native / JS 各 **285/285**），终态 **302/302**；工作树干净，未 push。
- 批准的攻击面 12 条：**修 5 条**（LC-23 ~ LC-27），另有 **2 件杂活**（文档计数、`priv` 清扫）。
- **4 条只记录不修**：ddmin 超线性、`visualize` 输出无上界、`--budget-ms 0` 的 1200 操作代价、`gen --inject` 的 n=0 空历史（其余 456 组合零静默）。
- 新增 **17 条确定性回归/守护测试**；没有依赖机器速度或长时间忙等的测试。
- 每条修复都有红灯（或 CLI 前后对比）+ 绿灯日志，落在仓库外证据目录。
- 四门（pinned `0.1.20261102`）与 CI 工具链 `0.1.20261117` 各自重跑：check 0 errors / fmt 干净 / 302 / wasm 绿。
- 下轮三件事：ddmin 探针复用、`visualize` 输出上界（需新契约）、`unconfirmed-witness` 的整条 JSON 夹具。

## 提交

| 提交 | 级别 | 摘要 |
| --- | --- | --- |
| `4ea18cc` | P3 | `--concurrency` 上界按十进制原文判（Double 在 1.0 附近回绕不得放行） |
| `1eb5a54` | **P2** | 按进程分组一次遍历（O(操作数×进程数) → O(操作数 + 进程数·log)） |
| `53dc086` | **P2** | `selfcheck` 的「结论未知」改报 3，不再折进 FAIL=1（+ 三处文档同步） |
| `8aaa9c4` | P3 | NoWitness 的成因在文本与 JSON 出口共用同一份复检结论 |
| `d6eff49` | P3 | 值位分类统一成一条判据（六个带值参数）+ LC-26 断言补强 |
| `afed05d` | 文档 | 测试计数 281 → 实测 302（DEMO §一、PLAN 状态行） |
| `2765ca1` | 杂活 | 两个内部结构标 `priv`，清掉 missing_priv 警告（31 → 29） |
| 本提交 | 文档 | 本报告落盘（`REPORT.md` 换成本轮记录） |

## 修复详情

### 1. `--concurrency 1.000000000000000001` 与 `1` 同输出、exit 0

**位置**：`cmd/lincheck/main.mbt` 的 `parse_double_arg` / `concurrency_in_domain`。

域判据只拿 Double 判 `value <= 1.0`，而解析器在 1.0 附近四舍五入（`1 + 1e-18`
就是 `1.0`，ulp(1.0) ≈ 2.2e-16）。原文严格大于 1 的一条带被静默当 1.0 接受 ——
与 LC-5（`2.5` 静默钳制）同一类「替用户改写意图」。

**修法**：`--concurrency` 的原文存进 `Cli.concurrency_text`，新增
`decimal_is_above_one(text)` 按十进制原文判上界；下界与不可表示面仍交给
Double 判据（`-0` → `-0.0`，`>= 0.0` 为真，放行）。`NaN` / `Infinity` / 指数
记法不在该解析器语法里。`1` / `1.0` / 30 个 0 / 30 个 9 / `0` / `-0` /
`0.000…01` 全部仍 exit 0（10 条守护断言）。

**证据**：`01-concurrency-domain-RED.log`（`1 != 2`）、`-GREEN.log`、`-cli.log`。

### 2. 分组是 O(操作数 × 进程数)：100k 进程历史 45 秒

**位置**：`src/visualize.mbt` 的 `render_ops` / `process_ids`、
`src/minimize.mbt` 的 `minimize_by_process_opt_with_config`。

三处都是 `for p in procs { for op in ops { … } }`（`render_ops` 里还写了两遍）。
`--budget-ms` 压不住这一段（它只压搜索）。`gen --processes 100000 --ops 1` 是
合法参数，于是 1e10 次比较。

**修法**：`src/history.mbt` 新增私有 `group_by_process`（`Map[Int32, Int]` 一次
装桶 + 按键升序换位）；`minimize_by_process` 里「逐个进程整块砍掉」的循环保留
逐次扫描（它砍的是正在收缩的 `current`，语义不同）。

**实测**：100000 操作 / 100000 进程 **45.2 s → 5.2 s**；20000 / 20000
1.9 s → 0.75 s；24000 / 3 与 20000 / 1 无变化。改前/改后两个二进制对 10 个输入
（合法 / 违规 / 空 / 多进程 / 多模型 + `minimize` 200 与 900 操作）输出与退出码
全部 `identical=True`；100k 的 100004 行除判定行的「已探索 N 个搜索节点」
（搜索侧墙钟噪声）外逐行相同。

**证据**：`02-render-timing.log`、`02-render-before-after.log`、
`bin-before.exe` / `bin-after.exe`。

### 3. `selfcheck` 把「结论未知」折进 FAIL = exit 1

**位置**：`cmd/lincheck/main.mbt` 的 `cmd_selfcheck`。

摘要里「结论未知」单独成行，退出码却与「误判违规 / 漏检注入」同为 1。
`docs/exit-codes.md` 把 1 定义为有效结论、3 定义为没有结论，并写明「3 不能被
四舍五入到任何邻居」；CI 拿同一个 1 分不清「检查器判错了」和「这台机器上没跑完」。

**修法**：抽 `selfcheck_verdict`：确定性错误（误判 / 漏检 / 注入档没跑满）→ 1；
有 Unknown → 3；全绿 → 0。结果行分 `PASS` / `UNKNOWN` / `FAIL`。

**红**：`selfcheck` 不接受 `--budget-ms`，唯一能造出 Unknown 的路径是 > 5 s 的
病态生成历史（会把机器速度写进断言）。按仓库既有做法锁决策表；反向验证把
`unknowns` 分支改回 `EXIT_VIOLATION` 立刻 `1 != 3` 变红。

**文档同步**：`docs/exit-codes.md` 新增 `## selfcheck`，`README.md` 退出码块、
`docs/DEMO.md` §六 各自补同口径说明。

**证据**：`04-selfcheck-verdict-REVERSE.log`；`selfcheck --seeds 300` 输出与
DEMO 逐行一致、exit 0。

### 4. NoWitness 的成因在两个出口上各写一套

**位置**：`cmd/lincheck/main.mbt` 的 `cmd_minimize` NoWitness 分支。

文本出口复检一次再按成因分流；JSON 出口写死
`reason:no-explainable-witness`，既无法表达成因、又少一次搜索。低预算抖动时
两种输出格式对同一条命令各说一套。

**修法**：`no_witness_report(original_n, outcome) -> (cause, text)` 一次产出，
JSON 取 `cause`、文本取 `text`。成因放**新增**的 `cause` 键（`data-inconsistency`
/ `concurrency-race` / `unknown`），`reason` 保持形状 token 不变：`unknown` 若写进
`verdict":"non-linearizable"` 的 `reason` 槽，会让只按 reason 分支的脚本把已确认
的违规读成「没有结论」。`depth` 仍然缺席（LC-18 判据不变）；API.md §4 / §7.1 同步。

**实测**：2-op stale read → `cause:concurrency-race` + 文本「属于并发竞态」；
单操作 `Cas(1->2)->true` → `cause:data-inconsistency` + 文本「历史数据自相矛盾」；
两者 exit 1 不变。断言用 `cause_of_text` 反向映射做往返一致 + 三支互斥。

**证据**：`05-no-witness-json-before-after.log`。

### 5. 值位分类六个入口各写一套

**位置**：`cmd/lincheck/main.mbt` 的 `parse_from` 值位分类。

上一轮只修了 `--history`；`--model -h` 报「未知模型 -h（可选 register, …）」，
而 `--history -h` / `--seed -h` 报「参数错误（缺值）」。退出码同为 2，属诊断
指向错误（用户会去查模型列表）。

**修法**：`value_is_option(flag, value)` 一条判据管六个带值参数 —— 值位以 `-`
开头时，只有该值位语法能接受它才算值。`--seed -1`、`--budget-ms -0`、
`--concurrency -0.0` 三条合法负值改前后都 exit 0（守护断言）；
`--ops -2147483648`、`--processes -0005` 仍走各自的负数/溢出路径。

**证据**：`07-value-position-before-after.log`（6 条前后对照，只有 `--model -h`
的文案变了）。

## 只记录、不修

- **ddmin 超线性**：100 / 200 / 400 操作见证 = 2.8 / 36.1 / 388.3 s（每翻倍
  ≈ ×11，≈ 二次到三次）。同一份 100 操作见证换预算（1 / 100 / 5000 ms =
  0.38 / 5.25 / 3.73 s）说明成本在主搜索而不在预算溢出。属 HANDOVER §22.5 已裁定
  的 LC-12 延伸，本轮只把曲线补成可复现实测表（`06-minimize-scaling.log`、
  `06-minimize-budget-probe.log`）。
- **`visualize` 输出无上界**：100000 进程 → 100004 行 / 7.1 MB。加截断等于新契约
  （会动 DEMO §三 的逐字断言），需先定口径。
- **`--budget-ms 0`**：1200 操作见证 + 无限预算在 120 s 上限下被 kill；`0/负值 =
  不设上限` 是已文档化语义，不改（`10-minimize-budget0.*`）。
- **`gen --inject` 的静默不注入**：456 组合（4 模型 × 进程 1..3 × ops 1..6 ×
  并发 0/0.5/1）零静默；仅 `--ops 0` 是合法空历史（`12-inject-scan.log`）。

## 复核（验过没问题）

- 三态全路径：`check` / `minimize` 大历史 `-b 1` → exit 3（文本与 `--json` 同一条
  reason）；非法区间 → 3（文件读得动）；`Nil` 结果 → 3；`gen --ops 0` 回喂
  `check` → 0 + `(0 个操作)`；`visualize` 非法区间 → 3 + 「时间轴不成立，已省略」
  （`08-three-state-verified.log`）。
- 合法值不被守卫误伤：`--processes 0` 钳制 1、`--ops 0` 空历史、`--seeds 0` →
  total = 1、1 ms / 100 ms 小预算；整数形态 `+5` / `0x10` / `" 5"` / `"5 "` 一律
  exit 2，`00007` = 7，`-2147483648`（任意前导零）= Int32 最小；互斥模式
  `--consistent --random` / `--inject --consistent` exit 2 并点名两者，同模式重复
  仍接受；跨命令白名单 `check --random` / `check --seeds` / `visualize --json` /
  `selfcheck --budget-ms` 全部 exit 2。
- `order_facts` 的 O(k²) 上界：只扫前 20000 对，截断分支用 `count_order_facts`
  复核总数，`n(n-1)` 用 Int64 不溢出；`i != j` 口径与「减去自身」一致（未改，
  靠 11-20 的测试）。
- 警告：`moon check` 29 warnings / 0 errors；缺 `priv` 的两处已清，其余
  （`unused_value: self`、`unreachable_code`、`result_error_return`、
  `unused_error_type`）属既有形态，不在清扫范围混改。

## 下轮三件事

1. **ddmin 探针结果复用**：同一 `remove_chunk` 结果在多轮里被反复重检；再加
   「大见证先做一次删除复验」的短路。预算已不是主成本。
2. **`visualize` 输出上界**：定「超过 N 个进程只画前 M 行 + 一行省略说明」或
   「行宽硬上限」的新契约，同步 DEMO §三。
3. **`unconfirmed-witness` 的整条 JSON 夹具**：这个已文档化的 token 至今没有
   稳定可触发的夹具；用人造 `CheckConfig` 白盒锁整条输出。

## 证据目录（仓库外）

`D:\code\moonbit\audit\2026-11-21\lincheck`：`REPORT.md`（本轮完整版）、
`evidence/`（红/绿日志、CLI 前后对比、计时表、`bin-before.exe` / `bin-after.exe`、
`fixtures/`）。