// 把 .build/issue/pages/*.html 套上布局，输出到 docs/issue/
// 每条问题一个页面；index.html 是索引，同时承载第一条记录。
import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.cwd();
const OUT = path.join(ROOT, 'docs/issue');
const PAGES_SRC = path.join(ROOT, '.build/issue/pages');
const LAYOUT = fs.readFileSync(path.join(ROOT, '.build/issue/_layout.html'), 'utf8');

const pages = [
  { file: 'index.html', title: '问题记录', crumb: '索引' },
  { file: 'macos-tunnel-proxy.html', title: 'macOS 隧道与系统代理残留', crumb: '1 · 隧道与代理残留' },
];

fs.mkdirSync(OUT, { recursive: true });

const nav = pages
  .map((p) => `<a href="${p.file === 'index.html' ? 'index.html' : p.file}">${p.crumb}</a>`)
  .join('');

let total = 0;
for (const p of pages) {
  const body = fs.readFileSync(path.join(PAGES_SRC, p.file), 'utf8');
  const html = LAYOUT
    .replace('{{TITLE}}', p.title)
    .replace('{{CRUMB}}', p.crumb)
    .replace('{{NAV}}', nav.replace(`href="${p.file}"`, `href="${p.file}" aria-current="page"`))
    .replace('{{BODY}}', body);
  const out = path.join(OUT, p.file);
  fs.writeFileSync(out, html);
  total += html.length;
  console.log('wrote', path.relative(ROOT, out), html.length);
}
console.log('total', total);
