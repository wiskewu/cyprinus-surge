import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const D = 'docs/diagrams';
const files = {
  arch: `${D}/01-architecture.html`,
  seq: `${D}/02-ai-request-path.html`,
  life: `${D}/03-failover-lifecycle.html`,
  flow: `${D}/04-rollout-workflow.html`,
};

const svgs = {};
const classes = new Set();
const styleBlocks = [];
for (const [k, f] of Object.entries(files)) {
  const h = fs.readFileSync(path.join(root, f), 'utf8');
  const svg = h.match(/<svg[\s\S]*?<\/svg>/)[0];
  svgs[k] = svg.replace(/<title id="archify-diagram-title">[\s\S]*?<\/title>/, '').replace(/<desc id="archify-diagram-description">[\s\S]*?<\/desc>/, '');
  [...svg.matchAll(/class="([^"]+)"/g)].forEach((m) => m[1].split(/\s+/).forEach((c) => classes.add(c)));
  styleBlocks.push(...[...h.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((m) => m[1]));
}

// Fonts (kept so latin metrics match the validated render) + SVG semantic rules + theme variables.
const fonts = styleBlocks[0].match(/@font-face\s*\{[^}]*\}/g) || [];
const main = styleBlocks.reduce((a, b) => (b.length > a.length ? b : a), '');
const rules = [...main.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ sel: m[1].replace(/\/\*[\s\S]*?\*\//g, '').trim(), body: m[2].trim() }));
const elementSel = /(^|[\s,>+~])(svg|text|tspan|rect|path|line|polyline|polygon|circle|ellipse|marker|defs|g|title|desc|use|clipPath|mask|pattern|linearGradient|stop)\b/;
const skip = /\.(viewer|archify|rail|toolbar|btn|legend|card|meta|shell|hero|chip|tab|drawer|toast|menu|overlay|preview|export|guide|lens)[-a-zA-Z0-9_]*/;
const seen = new Set();
const svgCss = [];
for (const r of rules) {
  const sel = r.sel;
  if (!sel || sel.startsWith('@') || /^\d|%$/.test(sel)) continue;
  const isVars = /:root|\[data-theme/.test(sel);
  const hitsClass = [...classes].some((c) => sel.includes('.' + c));
  const hitsElement = elementSel.test(sel) && !skip.test(sel);
  if (!(isVars || hitsClass || hitsElement)) continue;
  const key = sel + '|' + r.body;
  if (seen.has(key)) continue;
  seen.add(key);
  svgCss.push(`${sel}{${r.body}}`);
}

// 字体以文件形式引用，路径相对 docs/ 根目录；图目录在 docs/diagrams/fonts
const FONT_CSS = fonts.join('\n').replace(/url\(fonts\//g, 'url(diagrams/fonts/');
const CSS = `${FONT_CSS}\n${svgCss.join('\n')}`;
const tpl = fs.readFileSync(path.join(root, 'fragments/pages/home/template.html'), 'utf8');
const out = tpl
  .replace('/*ARCHIFY_CSS*/', () => CSS)
  .replace('<!--SVG_ARCH-->', () => svgs.arch)
  .replace('<!--SVG_SEQ-->', () => svgs.seq)
  .replace('<!--SVG_LIFE-->', () => svgs.life)
  .replace('<!--SVG_FLOW-->', () => svgs.flow);
fs.writeFileSync(path.join(root, 'docs/index.html'), out);
console.log('docs/index.html bytes', out.length, '| svg css rules', svgCss.length, '| font faces', fonts.length);
