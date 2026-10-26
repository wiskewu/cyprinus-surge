#!/usr/bin/env node
// 检查 bash 变量后紧跟多字节字符的写法：`$code，` 会被 bash 3.2 按字节
// 解析成变量 code\357，行为与预期不符。要求写成 `${code}，`。
// 只处理真正的展开位置：跳过注释、单引号、转义、`$_` 与已加花括号的引用。
import fs from "node:fs";

const roots = process.argv.slice(2);
if (roots.length === 0) {
  console.error("用法：node fragments/build/check-var-braces.mjs <文件...>");
  process.exit(2);
}

const NAME = /\$([A-Za-z_][A-Za-z0-9_]*)/g;
const hits = [];

function scan(file) {
  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
  let single = false;
  let double = false;
  lines.forEach((line, idx) => {
    let i = 0;
    while (i < line.length) {
      const ch = line[i];
      if (ch === "\\") {
        i += 2;
        continue;
      }
      if (!double && ch === "'") {
        single = !single;
        i++;
        continue;
      }
      if (!single && ch === '"') {
        double = !double;
        i++;
        continue;
      }
      if (!single && !double && ch === "#") break;
      if (!single && ch === "$") {
        NAME.lastIndex = i;
        const m = NAME.exec(line);
        if (m && m.index === i) {
          const name = m[1];
          const next = line[i + m[0].length] ?? "";
          const codePoint = next.codePointAt(0) ?? 0;
          if (name !== "_" && codePoint > 0x7f) {
            hits.push({ file, line: idx + 1, name, ch: next });
          }
          i += m[0].length;
          continue;
        }
      }
      i++;
    }
    // 单引号允许跨行，双引号在本仓库里不跨行，行末复位
    double = false;
  });
}

for (const r of roots) {
  if (fs.statSync(r).isDirectory()) {
    const walk = (dir) => {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = `${dir}/${e.name}`;
        if (e.isDirectory()) walk(p);
        else if (e.name.endsWith(".sh")) scan(p);
      }
    };
    walk(r);
  } else if (r.endsWith(".sh")) {
    scan(r);
  }
}

if (hits.length > 0) {
  for (const h of hits) {
    console.error(`${h.file}:${h.line}  $${h.name}${h.ch}  → 改成 \${${h.name}}`);
  }
  console.error(`变量后紧跟多字节字符 ${hits.length} 处：给变量加大括号`);
  process.exit(1);
}
console.log(`变量边界检查通过：${roots.length} 个输入`);
