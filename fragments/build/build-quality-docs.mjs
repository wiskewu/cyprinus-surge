// 把 bin/harden/*.sh 内联进手册页面，避免文档与脚本内容漂移
import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.cwd();
const SRC = path.join(ROOT, 'docs/quality');
const PAGES_SRC = path.join(ROOT, 'fragments/pages/quality');
const LAYOUT = fs.readFileSync(path.join(ROOT, 'fragments/pages/quality/_layout.html'), 'utf8');

const pages = [
  { file: 'index.html', title: 'SSH 加固', crumb: '0 · 总览' },
  { file: '01-client.html', title: '客户端配置', crumb: '1 · 客户端配置' },
  { file: '02-server.html', title: '服务端加固', crumb: '2 · 服务端加固' },
  { file: '03-verify.html', title: '验收与排障', crumb: '3 · 验收与排障' },
  { file: '04-reference.html', title: '参数与取舍', crumb: '4 · 参数与取舍' },
];

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const nav = pages
  .map((p) => `<a href="${p.file}">${p.crumb}</a>`)
  .join('');

let total = 0;
for (const p of pages) {
  let body = fs.readFileSync(path.join(PAGES_SRC, p.file), 'utf8');
  body = body.replace(/\{\{SCRIPT:([\w.-]+)\}\}/g, (_m, name) => {
    const f = path.join(SRC, 'scripts', name);
    if (!fs.existsSync(f)) throw new Error(`脚本不存在: ${name}`);
    return `<pre><code>${esc(fs.readFileSync(f, 'utf8').trimEnd())}</code></pre>`;
  });
  const html = LAYOUT
    .replace('{{TITLE}}', p.title)
    .replace('{{CRUMB}}', p.crumb)
    .replace('{{NAV}}', nav.replace(`href="${p.file}"`, `href="${p.file}" aria-current="page"`))
    .replace('{{BODY}}', body);
  const out = path.join(SRC, p.file);
  fs.writeFileSync(out, html);
  total += html.length;
  console.log('wrote', path.relative(ROOT, out), html.length);
}
console.log('total', total);