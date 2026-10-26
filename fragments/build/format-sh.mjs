#!/usr/bin/env node
// 用 shfmt 的 WASM 版本就地格式化脚本，等价 shfmt -i 2 -ci -bn -w。
// 用法：node fragments/build/format-sh.mjs <文件...>
import fs from "node:fs";
import { format } from "@wasm-fmt/shfmt";

const OPTS = { indent: 2, binaryNextLine: true, switchCaseIndent: true };
const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("用法：node fragments/build/format-sh.mjs <文件...>");
  process.exit(2);
}

let changed = 0;
for (const f of files) {
  const src = fs.readFileSync(f, "utf8");
  const out = format(src, f, OPTS);
  if (out !== src) {
    fs.writeFileSync(f, out);
    changed++;
    console.log(`已格式化 ${f}`);
  }
}
console.log(changed === 0 ? "无需改动" : `共格式化 ${changed} 个文件`);
