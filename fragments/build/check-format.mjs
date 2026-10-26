#!/usr/bin/env node
// 用 shfmt 的 WASM 版本检查脚本布局，免安装原生二进制。
// 规则与 shfmt -i 2 -ci -bn 等价：两空格缩进、case 分支缩进、二元运算符前置。
import fs from "node:fs";
import path from "node:path";
import { format } from "@wasm-fmt/shfmt";

const ROOTS = ["bin", "fragments/build"];
const OPTS = { indent: 2, binaryNextLine: true, switchCaseIndent: true };

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith(".sh")) out.push(p);
  }
  return out;
}

const files = ROOTS.flatMap((r) => (fs.existsSync(r) ? walk(r) : [])).sort();
const bad = [];
for (const f of files) {
  const src = fs.readFileSync(f, "utf8");
  let out;
  try {
    out = format(src, f, OPTS);
  } catch (err) {
    console.error(`${f}: shfmt 解析失败：${err.message}`);
    process.exitCode = 1;
    continue;
  }
  if (out !== src) bad.push(f);
}

if (bad.length > 0) {
  console.error("以下脚本格式与 shfmt 不一致：");
  for (const f of bad) console.error(`  ${f}`);
  console.error("修法：node fragments/build/format-sh.mjs <文件>");
  process.exit(1);
}
console.log(`shfmt 格式检查通过：${files.length} 个文件`);
