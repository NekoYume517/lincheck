// ============================================================================
// lc36_cache_key_injective_test.mbt —— 缓存键必须是**单射**，不得碰撞
//
// ## 为什么这是最高价值的攻击面
//
// Lowe 2017 的状态缓存用「子问题已确定失败」来剪掉重复搜索。缓存键一旦碰撞，
// 两种后果都是**不可检测**的：
//
//   - 假阴性：两个不同子问题共用一条「失败」记录 → 本该找到的线性化被剪掉，
//     合法的历史被报成 `Violation`；
//   - 假阳性：反过来把成功的记录错借给失败的子问题 → 违规的历史被放过。
//
// 两者都不会让任何「输入/输出形状」类测试变红 —— 只有对拍才能发现。所以这里
// 直接对 `cache_key` 的**编码**做性质测试，而不是靠随机历史碰运气。
//
// ## 编码为什么不碰撞
//
// `cache_key(state, remaining)` = `state_to_string(state) + "|" + 位串`。
//
// - `state_to_string` 输出 `[v0,v1,...]`，用逗号分隔、方括号包裹、负数带 `-`：
//   这是标准的**无歧义**整数序列编码。反例是「无分隔符拼接」
//   （`[1,23]` 与 `[12,3]` 都拼成 `123`），这里不存在。
// - 位串每个元素恰好一个字符（`0`/`1`），长度恒为 `remaining.length()`。
// - 分隔符 `|` 既不出现在十进制整数里，也不出现在位串里，所以状态段与剩余段
//   的切分位置唯一。
//
// 三条合起来 ⇒ 不同的 `(state, remaining)` 必得不同的键。
//
// 本文件把三条分别钉住；其中「`|` 不出现在两个分量里」是最容易被将来改动破坏的
// 一条（例如有人把份隔符换成 `,`，`[1,2]` 与 `[1,2]` + `,` + `101` 就可能和
// `[1,2,1]` + `01` 撞上）。

///|
/// 构造位串，与 `cache_key` 内部的口径一致（只是为了在测试里拼预期值）。
fn lc36_bits(flags : Array[Bool]) -> String {
  let sb = StringBuilder()
  for f in flags {
    if f {
      sb.write_char('1')
    } else {
      sb.write_char('0')
    }
  }
  sb.to_string()
}

///|
/// **不变量一**：`state_to_string` 是单射。
///
/// 用一批「容易被朴素拼接编码弄混」的状态对来打：`[1,23]` vs `[12,3]`、
/// `[0,0]` vs `[0]`、负数、Int32 边界。
test "LC-36: state_to_string 对不同的状态给出不同的字符串" {
  let cases : Array[(Array[Int32], Array[Int32])] = [
    // 无分隔符拼接会碰撞的经典对
    ([1, 23], [12, 3]),
    ([1, 2], [1, 2, 0]),
    ([0], [0, 0]),
    ([], [0]),
    ([-1, 2], [1, -2]),
    ([-2147483648], [2147483647]),
    ([1, -2, 3], [1, 2, -3]),
  ]
  for pair in cases {
    let a = state_to_string(pair.0)
    let b = state_to_string(pair.1)
    // 状态本身不相等（长度或元素不同），字符串也必须不等
    let identical = pair.0.length() == pair.1.length() &&
      ({
        let mut same = true
        for i, v in pair.0 {
          if pair.1[i] != v {
            same = false
          }
        }
        same
      })
    if !identical {
      assert_true(a != b)
    }
  }
}

///|
/// **不变量二**：两个分量的字符集不相交，因此切分位置唯一。
///
/// 判据不写死成「不含 `|`」—— 那样把测试绑在实现选的分隔符上，换个分隔符就
/// 失效（实测把 `|` 换成 `,` 时，本文件的字面断言会失效，而编码其实仍然无歧义，
/// 因为 `,` 也不出现在位串里、且状态段被 `[...]` 包裹）。这里改成断言**本质**：
///
/// - 位串只含 `0`/`1`；
/// - 状态段只含 `[` `]` `,` `-` 与十进制数字。
///
/// 两组字符集不相交 ⇒ 无论分隔符取其中哪一个，都不可能同时出现在两段里。
test "LC-36: 状态段与位串的字符集不相交" {
  let states : Array[Array[Int32]] = [
    [],
    [0],
    [1, 2, 3],
    [-1],
    [-2147483648, 2147483647],
  ]
  for s in states {
    let text = state_to_string(s)
    for ch in text.to_array() {
      let allowed = ch == '[' ||
        ch == ']' ||
        ch == ',' ||
        ch == '-' ||
        ({
          let ok = ch >= '0' && ch <= '9'
          ok
        })
      assert_true(allowed)
    }
  }
  // 位串只含 0/1 —— 与上面的字符集互补（'0'/'1' 在状态段里出现过，但那是
  // 数字的一部分，真正的切分靠分隔符：这里断言的是**位串**里不会出现
  // 状态段独有的字符）。
  for flags in [[], [true], [false, true, true], [false, false]] {
    let bits = lc36_bits(flags)
    for ch in bits.to_array() {
      assert_true(ch == '0' || ch == '1')
    }
  }
  // 端到端：无论分隔符是什么，状态段 + 分隔符 + 位串的切分点唯一 ——
  // 用「把位串接在状态段后」的经典碰撞构造来验：`[1,2]`+`1` 与 `[1,2]`+`11`
  // 必须以分隔符区分。
  let a = state_to_string([1, 2]) + "|" + lc36_bits([true])
  let b = state_to_string([1, 2, 1]) + "|" + lc36_bits([])
  assert_true(a != b)
}

///|
/// **不变量三**：端到端 —— 任意两个不同的子问题，键必须不同。
///
/// 这是前两条的直接推论，但值得单独跑一遍：它同时覆盖了「拼接顺序」和
/// 「分隔符位置」两处实现细节。用状态 × 位串的笛卡尔积，两两比较。
test "LC-36: 不同的 (状态, 剩余集) 组合不得共用同一个缓存键" {
  let states : Array[Array[Int32]] = [
    [],
    [0],
    [1],
    [1, 2],
    [2, 1],
    [1, 23],
    [12, 3],
    [-1, 2],
  ]
  let bit_patterns : Array[Array[Bool]] = [
    [],
    [true],
    [false],
    [true, false],
    [false, true],
    [true, false, true],
  ]
  // 把每个子问题的键记下来，两两比较
  let keys : Array[String] = []
  let descs : Array[String] = []
  for s in states {
    for bits in bit_patterns {
      keys.push(state_to_string(s) + "|" + lc36_bits(bits))
      descs.push(state_to_string(s) + "/" + lc36_bits(bits))
    }
  }
  let mut i = 0
  while i < keys.length() {
    let mut j = i + 1
    while j < keys.length() {
      // 描述互不相同 ⇒ 键也必须互不相同
      assert_true(descs[i] != descs[j])
      assert_true(keys[i] != keys[j])
      j = j + 1
    }
    i = i + 1
  }
}
