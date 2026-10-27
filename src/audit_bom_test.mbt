// audit_bom_test.mbt — JSONL 的 UTF-8 BOM（对抗性审计 2026-10-27，LC-11）
//
// 缺陷：带 BOM 的合法历史被整份拒收（exit 4）。
//
//   $ lincheck check --history bom.jsonl --model register
//   数据错误：JSONL 解析失败：bom.jsonl        # 内容完全合法，只是文件头多了 BOM
//
// `from_jsonl` 用 `raw.trim()` 处理每一行，而 MoonBit 的 `trim` 不剥 U+FEFF，
// 于是首行成了一个以 `\u{FEFF}{` 开头的非 JSON 文本。
//
// BOM 的来路很常见：Windows 记事本「另存为 UTF-8」、PowerShell 的
// `Out-File -Encoding utf8` / `>` 重定向、部分日志管道都会写它。这是
// 「Windows 上生成的历史喂不进去」的高频路径。
//
// 语义与 recall 对齐：**只剥首行行首的一个 BOM**。BOM 出现在非首行说明那
// 不是「文件头标记」而是数据本身的一部分（或文件被拼接坏了），仍应报错。

///|
fn bom_hist(text : String) -> Result[History, String] {
  try {
    let r = History::from_jsonl(text)
    match r {
      Ok(h) => Ok(h)
      Err(BadLine(no, reason)) => Err("line \{no}: \{reason}")
    }
  } catch {
    _ => Err("unexpected raise")
  }
}

///|
/// 一行合法操作（Write 1 → Ok）。
fn bom_row(id : Int32) -> String {
  "{\"id\":" +
  id.to_string() +
  ",\"process\":0,\"kind\":{\"tag\":\"Write\",\"value\":1},\"result\":{\"tag\":\"Ok\"},\"start\":0,\"end\":10}\n"
}

///|
/// 断言解析结果是「零操作的空历史」。
fn inspect_empty(r : Result[History, String], what : String) -> Unit raise {
  match r {
    Ok(h) => inspect(h.length(), content="0")
    Err(e) => inspect(e, content="\{what} 应可读为空历史")
  }
}

///|
test "LC-11: 首行带 UTF-8 BOM 的合法历史必须解析成功" {
  let text = "\u{FEFF}" + bom_row(0)
  match bom_hist(text) {
    Ok(h) => inspect(h.length(), content="1")
    Err(e) => inspect(e, content="BOM 被拒收（应为 Ok）")
  }
}

///|
test "LC-11: 只剥首行行首的一个 BOM —— 多行历史整份可读" {
  let text = "\u{FEFF}" + bom_row(0) + bom_row(1) + bom_row(2)
  match bom_hist(text) {
    Ok(h) => inspect(h.length(), content="3")
    Err(e) => inspect(e, content="BOM 被拒收（应为 Ok）")
  }
}

///|
test "LC-11: 无 BOM 的历史不受影响" {
  match bom_hist(bom_row(0) + bom_row(1)) {
    Ok(h) => inspect(h.length(), content="2")
    Err(e) => inspect(e, content="正常输入被误拒")
  }
  // 空输入与空行
  inspect_empty(bom_hist(""), "空输入")
  inspect_empty(bom_hist("\n\n"), "只有空行")
  // 只有 BOM、没有内容：剥掉后为空 → 空历史
  inspect_empty(bom_hist("\u{FEFF}"), "只有 BOM")
  // BOM + 换行 + 好行
  match bom_hist("\u{FEFF}\n" + bom_row(0)) {
    Ok(h) => inspect(h.length(), content="1")
    Err(e) => inspect(e, content="首行 BOM 后跟空行应可读")
  }
}

///|
test "LC-11: BOM 出现在非首行仍报错（与 recall 语义对齐）" {
  // 第二行行首的 BOM 不是「文件头标记」，而是被拼接坏的数据
  let text = bom_row(0) + "\u{FEFF}" + bom_row(1)
  match bom_hist(text) {
    Ok(_) => inspect("非首行 BOM 被静默接受", content="应报错")
    Err(e) => inspect(e.contains("line 2"), content="true")
  }
}

///|
test "LC-11: 首行行首 BOM 只剥一个，不重复剥" {
  // 两个 BOM：剥掉一个后剩下的那个仍会让解析失败——说明实现只剥一个
  let text = "\u{FEFF}\u{FEFF}" + bom_row(0)
  match bom_hist(text) {
    Ok(_) => inspect("剥了不止一个", content="应报错")
    Err(e) => inspect(e.contains("line 1"), content="true")
  }
}

///|
test "LC-11: 首行有前导空白时 BOM 仍被剥（trim 之后再看 BOM）" {
  // 行首空白先被 trim 掉，BOM 落在 trim 结果的开头
  let text = "  \u{FEFF}" + bom_row(0)
  match bom_hist(text) {
    Ok(h) => inspect(h.length(), content="1")
    Err(e) => inspect(e, content="空白+BOM 首行应可读")
  }
}

///|
test "LC-11 守护: 坏 JSON 的错误行号不因剥 BOM 而偏移" {
  // 第 3 行坏：剥 BOM 不能让行号从 3 变成 2
  let text = "\u{FEFF}" + bom_row(0) + bom_row(1) + "NOT JSON\n"
  match bom_hist(text) {
    Ok(_) => inspect("坏行被接受", content="应报错")
    Err(e) => inspect(e.contains("line 3"), content="true")
  }
}
