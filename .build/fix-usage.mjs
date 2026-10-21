import fs from 'node:fs';
const p = 'docs/deploy/scripts/50-render-client.sh';
let s = fs.readFileSync(p, 'utf8');
const old = `    -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;`;
const neu = `    -h|--help) usage; exit 0 ;;`;
if (!s.includes(old)) throw new Error('help anchor');
s = s.replace(old, neu);
const anchor = '# ---------- 解析参数 ----------';
const usage = `usage() {
  cat <<'USAGE'
用法：
  bash 50-render-client.sh client.env                   # 单份（完全按 client.env + 命令行变量）
  bash 50-render-client.sh client.env --all             # 一次生成 desktop / android / ios
  bash 50-render-client.sh client.env desktop android   # 只生成指定端
  OUTDIR=./data bash 50-render-client.sh client.env --all

单份模式：OUT=... 或默认 ./sing-box-client.json，所有变量由你决定。
多端模式：内置预设覆盖平台相关项（CLIENT_MIXED / AUTO_DETECT_INTERFACE），其余来自 client.env。
          桌面若报 not valid in its context，在前面加 AUTO_DETECT_INTERFACE=false。
USAGE
}

${anchor}`;
s = s.replace(anchor, usage);
fs.writeFileSync(p, s);
console.log('usage fixed');
