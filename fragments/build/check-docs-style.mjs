#!/usr/bin/env node
// 按技术文档标准检查页面措辞：不写营销词、破折号、总结铺垫句、空泛程度词、
// 泛指引用、第一人称与感叹号。检查对象是页面源文件，生成物不重复检查。
import fs from "node:fs";
import path from "node:path";

const RULES = {
  破折号: /——/,
  营销词: /强大|极致|完美|无缝|轻松|神器|炸裂|超强|领先|顶级|秒开|保姆级|一键搞定/,
  总结铺垫: /总之|综上|总的来说|值得一提的是|需要注意的是|不难发现|可以看到|接下来|下面我们|让我们|本文将|本节将/,
  空泛程度词: /非常|十分|极其|极大地|更好地|更加/,
  泛指引用: /上述|前述|上一节|下一节|见上文|如下图所示|下面介绍/,
  第一人称: /我们|你们/,
  感叹号: /！/,
};

// 外部原话与固定搭配：检查前先剔除
const ALLOW = ["您必须接受我们的服务条款"];
const IGNORE = "<!-- docs-style:ignore -->";

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith(".html")) out.push(p);
  }
  return out;
}

const files = [...walk("fragments/pages"), ...fs.readdirSync("docs").filter((f) => f.endsWith(".html")).map((f) => path.join("docs", f))].sort();

const hits = [];
for (const f of files) {
  const lines = fs.readFileSync(f, "utf8").split(/\r?\n/);
  lines.forEach((line, idx) => {
    if (line.includes(IGNORE)) return;
    let text = line;
    for (const a of ALLOW) text = text.split(a).join("");
    text = text.replace(/<[^>]+>/g, "");
    for (const [name, re] of Object.entries(RULES)) {
      const m = re.exec(text);
      if (m) hits.push({ file: f, line: idx + 1, rule: name, frag: text.slice(Math.max(0, m.index - 20), m.index + 20).trim() });
    }
  });
}

if (hits.length > 0) {
  for (const h of hits) console.error(`${h.file}:${h.line} [${h.rule}] …${h.frag}…`);
  console.error(`页面措辞 ${hits.length} 处需要处理`);
  process.exit(1);
}
console.log(`页面措辞检查通过：${files.length} 个源页面`);
