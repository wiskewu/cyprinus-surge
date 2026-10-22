// 把 docs/quality/scripts/* 内联进手册页面，避免文档与脚本内容漂移
import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.cwd();
const SRC = path.join(ROOT, 'docs/quality');
const PAGES_SRC = path.join(ROOT, '.build/quality/pages');
const LAYOUT = fs.readFileSync(path.join(ROOT, '.build/quality/_layout.html'), 'utf8');

const pages = [
  { file: 'index.html', title: '总览', crumb: '0 · 总览' },
  { file: '01-how.html', title: '工作原理', crumb: '1 · 工作原理' },
  { file: '02-keys.html', title: '多客户端密钥', crumb: '2 · 多客户端密钥' },
  { file: '03-deploy.html', title: '部署', crumb: '3 · 部署' },
  { file: '04-verify.html', title: '验收与运维', crumb: '4 · 验收与运维' },
  { file: '05-ops.html', title: '排查', crumb: '5 · 排查' },
  { file: '06-rollback.html', title: '卸载与回退', crumb: '6 · 卸载与回退' },
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