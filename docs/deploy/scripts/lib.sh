#!/usr/bin/env bash
# lib.sh —— 所有脚本共用的函数。不要单独运行，被 source。
#
# 注意：库不得修改调用方的 shell 选项。每个脚本在 source 之前自己声明
# set -euo pipefail / set -uo pipefail；这里再设一遍会把 -e（errexit）
# 强加给只想要 -u 的检查类脚本，导致某个管道返回非 0 时整个脚本静默退出。

DEPLOY_DIR="${DEPLOY_DIR:-/etc/sing-box}"
ENVFILE="${ENVFILE:-$DEPLOY_DIR/deploy.env}"
CLIENT_ENV="${CLIENT_ENV:-$DEPLOY_DIR/client.env}"
DEVICES_LIST="${DEVICES_LIST:-$DEPLOY_DIR/devices.list}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SELF_DIR/templates"

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
  [ "${SKIP_ROOT:-0}" = "1" ] && return 0
  [ "$(id -u)" = "0" ] || die "需要 root：sudo bash $0"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1，请先跑 00-bootstrap.sh"
}

# 读取 KEY=VALUE 环境文件（不执行其中的命令）
load_env() {
  local f="$1"
  [ -f "$f" ] || die "找不到 $f"
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

# 只替换模板里出现的 ${KEY}；值里的 & | \ 会被转义，跨 GNU/BSD sed 可用
render_vars() {
  local t="$1" o="$2" k v
  [ -f "$t" ] || die "模板不存在：$t"
  cp "$t" "$o"
  for k in $(grep -o '\${[A-Z_][A-Z0-9_]*}' "$t" | tr -d '${}' | sort -u); do
    v="${!k-}"
    [ -n "$v" ] || die "变量 $k 未设置（检查 ${ENVFILE}）"
    v="$(printf '%s' "$v" | sed -e 's/[&\\|]/\\&/g')"
    sed -i.bak "s|\${$k}|$v|g" "$o" && rm -f "$o.bak"
  done
}

# 把片段文件的原始内容塞进占位符（用 awk，避免 sed 转义地狱）
inject_block() {
  local f="$1" ph="$2" frag="$3"
  [ -f "$frag" ] || die "片段不存在：$frag"
  awk -v ph="$ph" -v frag="$frag" '
    index($0, ph) { while ((getline line < frag) > 0) print line; close(frag); next }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# 用逗号拼接多个 JSON 片段
join_json() {
  local out="" f
  for f in "$@"; do
    [ -n "$out" ] && out="$out,"$'\n'
    out="$out$(cat "$f")"
  done
  printf '%s' "$out"
}

json_valid() {
  command -v jq >/dev/null 2>&1 || return 0   # 没有 jq 就跳过，sing-box check 仍会报语法错
  jq -e . "$1" >/dev/null 2>&1 || die "JSON 语法错误：$1（用 jq . 看一眼）"
}

sb_check() {
  if [ -x "$SB_BIN" ]; then
    "$SB_BIN" check -c "$1" || die "sing-box 拒绝该配置：$1"
    log "配置校验通过：$1"
  else
    warn "未找到 ${SB_BIN}，跳过 sing-box check"
  fi
}

rand_pass() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-20}"; }

# ===== 设备名单 devices.list =====
# 格式：每行「名字 凭据 平台」，# 开头是注释。
# 一台设备一个凭据，同时当 VLESS 的 uuid 和 Hysteria2 的 password 用——
# 这样「吊销一台」就是删一行，两条入口同时失效，不会漏。
# 代价是同一个值出现在两个协议里（个人自用可接受，换来的是吊销的原子性）。
valid_device_name() { case "${1:-}" in "" | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

device_rows() {
  [ -f "$DEVICES_LIST" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$DEVICES_LIST"
}

# device_get <名字> → 输出「凭据 平台」；不存在则返回 1
device_get() {
  local n c p
  while read -r n c p; do
    if [ "$n" = "$1" ]; then printf '%s %s\n' "$c" "${p:-desktop}"; return 0; fi
  done < <(device_rows)
  return 1
}

device_exists() { device_get "$1" >/dev/null 2>&1; }
