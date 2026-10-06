/// # 抽象对象模型（model.mbt）
///
/// 线性一致性检查器不需要知道"真实的对象"长什么样，只需要两件事：
///
/// 1. 一个**状态**（能编码成整数向量，便于哈希与比较）
/// 2. 一个 `apply(state, op) -> (新状态, 期望结果)?` 函数
///
/// 只要 `apply` 说"在这个状态下执行 op 该返回什么"，检查器就能用纯粹的搜索
/// 回答"是否存在一个合法全序"。不同的数据结构（寄存器、计数器、集合、队列）
/// 只是 `apply` 不同而已——这就是 `Model` trait 的全部意义。
///
/// ## 为什么 `State = Array[Int]`
///
/// 泛型状态会让哈希缓存变得复杂（要泛型哈希、泛型相等），而实际要检查的对象
/// 状态都很小。统一成 `Array[Int]` 后，缓存键可以直接拼成字符串，实现简单、
/// 跨模型复用。每个模型在文档里约定自己的编码方式。
///
/// ## 关于 `Model` 不能当类型
///
/// MoonBit 没有 trait object，`model : Model` 这种写法编译不过。
/// 因此对外统一用 `AnyModel` 枚举包装（它自己也 `impl Model`），
/// 内部算法写成泛型 `fn[M : Model]`，编译期单态化，零动态分发开销。

///|
/// 状态：统一的整数向量表示。
pub type State = Array[Int32]

///|
/// 对象模型接口。
///
/// - `name`：模型名，用于 CLI 与报错
/// - `init`：初始状态
/// - `apply`：在给定状态下执行操作，返回（新状态, 期望返回的结果）；非法操作返回 None
/// - `state_eq` / `state_hash`：缓存用的判等与哈希
pub trait Model {
  fn name(Self) -> String
  fn init(Self) -> State
  fn apply(Self, State, OpKind) -> (State, OpResult)?
  fn state_eq(Self, State, State) -> Bool
  fn state_hash(Self, State) -> Int32
}

// ============================================================
// 通用工具
// ============================================================

///|
/// 复制一个状态数组。模型绝不能就地修改传入的状态，
/// 否则搜索回溯时会污染兄弟分支。
pub fn state_copy(state : State) -> State {
  state.copy()
}

///|
/// 状态 → 字符串，形如 `[1,2,3]`。用于缓存键、解释文本与测试断言。
pub fn state_to_string(state : State) -> String {
  let sb = StringBuilder()
  sb.write_string("[")
  for i, v in state {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(v.to_string())
  }
  sb.write_string("]")
  sb.to_string()
}

///|
/// 多项式哈希：`h = 17; h = h * 31 + x`。
///
/// 固定算法（不引入随机种子）是刻意的：同一输入两次运行必须得到同样的
/// 缓存键序列，否则无法复现 bug。整型溢出按 MoonBit 的补码回绕处理，仍然确定。
pub fn poly_hash(state : State) -> Int32 {
  let mut h = 17
  for x in state {
    h = h * 31 + x
  }
  h
}

///|
/// 逐元素比较两个状态数组。
pub fn states_equal(a : State, b : State) -> Bool {
  if a.length() != b.length() {
    false
  } else {
    let mut eq = true
    for i, v in a {
      if v != b[i] {
        eq = false
      }
    }
    eq
  }
}

// ============================================================
// register：单寄存器
// ============================================================

///|
/// 单寄存器模型。
///
/// 状态编码：`[value]`，初始 `[0]`。
///
/// | 操作 | 条件 | 新状态 | 期望结果 |
/// |---|---|---|---|
/// | `Write(v)` | 无 | `[v]` | `Ok` |
/// | `Read` | 无 | 不变 | `Value(v)` |
/// | `Cas(e, n)` | `v == e` | `[n]` | `Bool(true)` |
/// | `Cas(e, n)` | `v != e` | 不变 | `Bool(false)` |
///
/// 其余操作（Append/Pop）在此模型上非法，返回 None。
pub(all) struct RegisterModel {} derive(Debug)

///|
pub impl Model for RegisterModel with fn name(self) {
  "register"
}

///|
pub impl Model for RegisterModel with fn init(self) {
  [0]
}

///|
pub impl Model for RegisterModel with fn apply(self, state, kind) {
  let current = state[0]
  match kind {
    Write(v) => Some(([v], Ok))
    Read => Some((state_copy(state), Value(current)))
    Cas(e, n) =>
      if current == e {
        Some(([n], OpResult::Bool(true)))
      } else {
        Some((state_copy(state), OpResult::Bool(false)))
      }
    Append(_) => None
    Pop => None
  }
}

///|
pub impl Model for RegisterModel with fn state_eq(self, a, b) {
  states_equal(a, b)
}

///|
pub impl Model for RegisterModel with fn state_hash(self, state) {
  poly_hash(state)
}

///|
/// 构造单寄存器模型。
pub fn register_model() -> RegisterModel {
  RegisterModel::{ }
}

// ============================================================
// counter：单调计数器
// ============================================================

///|
/// 单调计数器模型。
///
/// 状态编码：`[value]`，初始 `[0]`。
///
/// 递增在历史里记录为 `Write(v)`——`v` 就是"递增之后的值"。
/// 模型只允许严格递增（`v > 当前值`），因此任何回退的写都会被判为非法，
/// 这正是"单调"的含义，也让检查器能抓住计数器回退这类真实 bug。
///
/// | 操作 | 条件 | 新状态 | 期望结果 |
/// |---|---|---|---|
/// | `Write(v)` | `v > value` | `[v]` | `Ok` |
/// | `Write(v)` | `v <= value` | — | 非法（None） |
/// | `Read` | 无 | 不变 | `Value(value)` |
pub(all) struct CounterModel {} derive(Debug)

///|
pub impl Model for CounterModel with fn name(self) {
  "counter"
}

///|
pub impl Model for CounterModel with fn init(self) {
  [0]
}

///|
pub impl Model for CounterModel with fn apply(self, state, kind) {
  let current = state[0]
  match kind {
    Write(v) =>
      if v > current {
        Some(([v], Ok))
      } else {
        None // 计数器不允许回退
      }
    Read => Some((state_copy(state), Value(current)))
    Cas(_, _) => None
    Append(_) => None
    Pop => None
  }
}

///|
pub impl Model for CounterModel with fn state_eq(self, a, b) {
  states_equal(a, b)
}

///|
pub impl Model for CounterModel with fn state_hash(self, state) {
  poly_hash(state)
}

///|
/// 构造单调计数器模型。
pub fn counter_model() -> CounterModel {
  CounterModel::{ }
}

// ============================================================
// set：64 位位图集合
// ============================================================

///|
/// 集合模型，值域限定 0..63。
///
/// 状态编码：`[低 32 位掩码, 高 32 位掩码]`。
/// MoonBit 的 `Int` 是 32 位（`1 << 63` 会溢出成负数），所以 64 位掩码拆成两个 Int，
/// 而不是硬塞进一个。这样第 31..63 位也能正确表示。
///
/// | 操作 | 条件 | 新状态 | 期望结果 |
/// |---|---|---|---|
/// | `Append(v)` | `0 <= v <= 63`（重复写入也合法） | 置位 v | `Ok` |
/// | `Pop` | 集合非空 | 清除最小元素 | `Bool(true)` |
/// | `Pop` | 集合为空 | 不变 | `Bool(false)` |
/// | `Read` | 无 | 不变 | `Value(最小元素)`，空集时 `Value(-1)` |
///
/// `Pop` 选择**最小元素**是刻意的确定性约定：不指定的话同一状态会有多个
/// 可能的"期望返回"，搜索就变成不确定的了。
pub(all) struct SetModel {} derive(Debug)

///|
/// 掩码位宽：每半个掩码 32 位。
const SET_HALF_BITS : Int32 = 32

///|
/// 把位序号拆成（半个掩码的下标, 位内偏移）。
fn set_bit_pos(v : Int32) -> (Int32, Int32) {
  if v < SET_HALF_BITS {
    (0, v)
  } else {
    (1, v - SET_HALF_BITS)
  }
}

///|
/// 读取某个值是否在集合中。
fn set_contains(state : State, v : Int32) -> Bool {
  if v < 0 || v > 63 {
    false
  } else {
    let (half, bit) = set_bit_pos(v)
    ((state[half] >> bit) & 1) == 1
  }
}

///|
/// 返回置位后的新掩码对（不修改输入）。
fn set_insert(state : State, v : Int32) -> State {
  let (half, bit) = set_bit_pos(v)
  let next = state_copy(state)
  next[half] = next[half] | (1 << bit)
  next
}

///|
/// 返回清除后的新掩码对（不修改输入）。
fn set_remove(state : State, v : Int32) -> State {
  let (half, bit) = set_bit_pos(v)
  let next = state_copy(state)
  next[half] = next[half] & (1 << bit).lnot()
  next
}

///|
/// 找最小在位元素；空集返回 -1。
fn set_min(state : State) -> Int32 {
  let mut result = -1
  let mut i = 0
  while i < 64 && result < 0 {
    if set_contains(state, i) {
      result = i
    }
    i = i + 1
  }
  result
}

///|
pub impl Model for SetModel with fn name(self) {
  "set"
}

///|
pub impl Model for SetModel with fn init(self) {
  [0, 0]
}

///|
pub impl Model for SetModel with fn apply(self, state, kind) {
  match kind {
    Append(v) =>
      if v < 0 || v > 63 {
        None // 超出 64 位值域，判非法
      } else {
        Some((set_insert(state, v), Ok))
      }
    Write(v) =>
      // Write 在集合上等价于"加入"：写入即包含。
      if v < 0 || v > 63 {
        None
      } else {
        Some((set_insert(state, v), Ok))
      }
    Pop => {
      let smallest = set_min(state)
      if smallest < 0 {
        Some((state_copy(state), OpResult::Bool(false)))
      } else {
        Some((set_remove(state, smallest), OpResult::Bool(true)))
      }
    }
    Read => Some((state_copy(state), Value(set_min(state))))
    Cas(_, _) => None
  }
}

///|
pub impl Model for SetModel with fn state_eq(self, a, b) {
  states_equal(a, b)
}

///|
pub impl Model for SetModel with fn state_hash(self, state) {
  poly_hash(state)
}

///|
/// 构造集合模型。
pub fn set_model() -> SetModel {
  SetModel::{ }
}

// ============================================================
// queue：FIFO 队列
// ============================================================

///|
/// 队列模型。
///
/// 状态编码：`[长度, e0, e1, ..., e(n-1)]`，第 0 位是队首。
/// 入队追加到末尾，出队从队首取走——标准 FIFO 语义。
///
/// | 操作 | 条件 | 新状态 | 期望结果 |
/// |---|---|---|---|
/// | `Append(v)` | 无 | 尾部追加 v | `Ok` |
/// | `Pop` | 非空 | 移除队首 | `Value(队首)` |
/// | `Pop` | 空 | 不变 | `Empty` |
/// | `Read` | 无 | 不变 | `Value(队首)`，空队时 `Value(-1)` |
pub(all) struct QueueModel {} derive(Debug)

///|
/// 队列状态的长度字段下标。
const QUEUE_LEN : Int32 = 0

///|
/// 队列当前元素个数。
fn queue_len(state : State) -> Int32 {
  state[QUEUE_LEN]
}

///|
pub impl Model for QueueModel with fn name(self) {
  "queue"
}

///|
pub impl Model for QueueModel with fn init(self) {
  [0]
}

///|
pub impl Model for QueueModel with fn apply(self, state, kind) {
  let n = queue_len(state)
  match kind {
    Append(v) => {
      // 新状态 = 长度 +1，末尾追加 v（绝不动原数组）
      let next : State = []
      next.push(n + 1)
      let mut i = 0
      while i < n {
        next.push(state[QUEUE_LEN + 1 + i])
        i = i + 1
      }
      next.push(v)
      Some((next, Ok))
    }
    Pop =>
      if n == 0 {
        Some((state_copy(state), Empty))
      } else {
        let front = state[QUEUE_LEN + 1]
        let next : State = []
        next.push(n - 1)
        let mut i = 1
        while i < n {
          next.push(state[QUEUE_LEN + 1 + i])
          i = i + 1
        }
        Some((next, Value(front)))
      }
    Read =>
      if n == 0 {
        Some((state_copy(state), Value(-1)))
      } else {
        Some((state_copy(state), Value(state[QUEUE_LEN + 1])))
      }
    Write(_) => None
    Cas(_, _) => None
  }
}

///|
pub impl Model for QueueModel with fn state_eq(self, a, b) {
  states_equal(a, b)
}

///|
pub impl Model for QueueModel with fn state_hash(self, state) {
  poly_hash(state)
}

///|
/// 构造队列模型。
pub fn queue_model() -> QueueModel {
  QueueModel::{ }
}

// ============================================================
// AnyModel：存在类型包装（trait 不能当类型用）
// ============================================================

///|
/// 运行期动态分发的模型包装。
///
/// MoonBit 没有 trait object，所以 CLI 想"按名字选模型"就必须有一个具体类型。
/// `AnyModel` 自己 `impl Model`，因此泛型函数（例如 `check_with`）可以直接吃它，
/// 也可以拆开传具体模型享受单态化。
pub(all) enum AnyModel {
  Register(RegisterModel)
  Counter(CounterModel)
  Set(SetModel)
  Queue(QueueModel)
} derive(Debug)

///|
pub impl Model for AnyModel with fn name(self) {
  match self {
    Register(m) => m.name()
    Counter(m) => m.name()
    Set(m) => m.name()
    Queue(m) => m.name()
  }
}

///|
pub impl Model for AnyModel with fn init(self) {
  match self {
    Register(m) => m.init()
    Counter(m) => m.init()
    Set(m) => m.init()
    Queue(m) => m.init()
  }
}

///|
pub impl Model for AnyModel with fn apply(self, state, kind) {
  match self {
    Register(m) => m.apply(state, kind)
    Counter(m) => m.apply(state, kind)
    Set(m) => m.apply(state, kind)
    Queue(m) => m.apply(state, kind)
  }
}

///|
pub impl Model for AnyModel with fn state_eq(self, a, b) {
  match self {
    Register(m) => m.state_eq(a, b)
    Counter(m) => m.state_eq(a, b)
    Set(m) => m.state_eq(a, b)
    Queue(m) => m.state_eq(a, b)
  }
}

///|
pub impl Model for AnyModel with fn state_hash(self, state) {
  match self {
    Register(m) => m.state_hash(state)
    Counter(m) => m.state_hash(state)
    Set(m) => m.state_hash(state)
    Queue(m) => m.state_hash(state)
  }
}

///|
/// 按名字选模型。
///
/// 未知名字**不回退**，返回 `None`。静默回退到一个默认模型是危险的：
/// 用户敲 `--model reqister` 拼错一个字母，工具会拿 register 模型跑完，
/// 然后给出一个看起来权威但完全不是他要的结论。
///
/// 需要默认值的调用方应显式写 `model_by_name(name).unwrap_or(register_model())`，
/// 让「用了默认值」这件事在代码里可见。
pub fn model_by_name(name : String) -> AnyModel? {
  match name {
    "register" => Some(Register(register_model()))
    "counter" => Some(Counter(counter_model()))
    "set" => Some(Set(set_model()))
    "queue" => Some(Queue(queue_model()))
    _ => None
  }
}

///|
/// `model_by_name` 的便利版本：未知名字回退到 `register`。
///
/// 仅供**已知名字合法**的场景（测试、内建示例）。CLI 必须用 `model_by_name`
/// 并对 `None` 报用法错误，否则拼错模型名会静默跑错模型。
pub fn model_or_default(name : String) -> AnyModel {
  match model_by_name(name) {
    Some(m) => m
    None => Register(register_model())
  }
}

///|
/// 全部模型的规范名字，供 CLI 打印用法。
pub fn model_names() -> Array[String] {
  ["register", "counter", "set", "queue"]
}
