// 把 bin/deploy/*.sh 内联进手册页面，避免文档与脚本内容漂移
import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.cwd();
const SRC = path.join(ROOT, 'docs/deploy');
const PAGES_SRC = path.join(ROOT, 'fragments/pages/deploy');
const LAYOUT = fs.readFileSync(path.join(ROOT, 'fragments/pages/deploy/_layout.html'), 'utf8');

const pages = [
  { file: 'index.html', title: '总览与准备', crumb: '0 · 总览与准备' },
  { file: '01-init.html', title: '系统初始化', crumb: '1 · 系统初始化' },
  { file: '02-install.html', title: '安装与密钥', crumb: '2 · 安装与密钥' },
  { file: '03-server.html', title: '服务端配置', crumb: '3 · 服务端配置' },
  { file: '04-hy2.html', title: '可选：Hysteria2', crumb: '4 · 可选 Hysteria2' },
  { file: '05-client.html', title: '客户端', crumb: '5 · 客户端' },
  { file: '06-ops.html', title: '验收与备份', crumb: '6 · 验收与备份' },
  { file: 'onekey.html', title: '一键脚本', crumb: '一键' },
  { file: '07-subscription.html', title: '订阅与用量显示', crumb: '7 · 订阅与用量' },
  { file: 'troubleshooting.html', title: '排查手册', crumb: '排查' },
];

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const nav = pages
  .map((p) => `<a href="${p.file}">${p.crumb}</a>`)
  .join('');

let total = 0;
for (const p of pages) {
  let body = fs.readFileSync(path.join(PAGES_SRC, p.file), 'utf8');
  body = body.replace(/\{\{SCRIPT:([\w.-]+)\}\}/g, (_m, name) => {
    const f = path.join(ROOT, 'bin/deploy', name);
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
