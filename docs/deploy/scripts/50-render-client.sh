#!/usr/bin/env bash
# 50-render-client.sh —— 在【客户端机器】生成 sing-box 配置。
#
# 用法：
#   bash 50-render-client.sh client.env                    # 单份（完全按 client.env + 命令行变量）
#   bash 50-render-client.sh client.env --all              # 一次生成 desktop / android / ios 三份
#   bash 50-render-client.sh client.env desktop android    # 只生成指定端
#   OUTDIR=./data bash 50-render-client.sh client.env --all
#
# 单份模式（不带端名）语义不变：OUT=... 或默认 ./sing-box-client.json，所有变量由你决定。
# 多端模式会用内置预设覆盖「平台相关」的两项（CLIENT_MIXED / AUTO_DETECT_INTERFACE），
# 其余仍来自 client.env；需要特殊组合时用单份模式自己指定。
set -euo pipefail

# 第一个参数如果不是 - 开头，就当成环境文件
ENVFILE="./client.env"
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then ENVFILE="$1"; shift; fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

usage() {
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

# ---------- 解析参数 ----------
TARGETS=()
ALL=0
for a in "$@"; do
  case "$a" in
    --all) ALL=1 ;;
    -h|--help) usage; exit 0 ;;
    desktop|android|ios) TARGETS+=("$a") ;;
    *) die "未知参数：$a（可选：--all / desktop / android / ios）" ;;
  esac
done
if [ "$ALL" = 1 ]; then TARGETS=(desktop android ios); fi

[ -f "$ENVFILE" ] || die "找不到 ${ENVFILE}（从服务器 /etc/sing-box/client.env 复制过来）"

# ---------- 读环境：命令行显式传入的优先 ----------
_ov_names=("CLIENT_MIXED" "AI_MODE" "AUTO_DETECT_INTERFACE" "DNS_CN" "DNS_REMOTE" "ENABLE_HY2")
_ov_vals=()
for _i in "${!_ov_names[@]}"; do _ov_vals[$_i]="${!_ov_names[$_i]:-}"; done

load_env "$ENVFILE"

for _i in "${!_ov_names[@]}"; do
  [ -n "${_ov_vals[$_i]}" ] && export "${_ov_names[$_i]}=${_ov_vals[$_i]}"
done
unset _ov_names _ov_vals _i

: "${AI_MODE:=main}"
: "${CLIENT_MIXED:=1}"
: "${DNS_CN:=223.5.5.5}"
: "${DNS_REMOTE:=1.1.1.1}"
: "${AUTO_DETECT_INTERFACE:=true}"
OUTDIR="${OUTDIR:-.}"

# ---------- 校验与派生 ----------
validate_common() {
  case "${AUTO_DETECT_INTERFACE}" in 0|false|no|off) AUTO_DETECT_INTERFACE=false ;; *) AUTO_DETECT_INTERFACE=true ;; esac
  if [ "$AI_MODE" = "dedicated" ]; then
    [ -n "${AI_SOCKS_SERVER:-}" ] || die "AI_MODE=dedicated 但 AI_SOCKS_SERVER 为空"
    [ -n "${AI_SOCKS_USER:-}" ]   || die "AI_MODE=dedicated 但 AI_SOCKS_USER 为空"
  fi
  # 两个出口标签：模板里只认标签，不写死
  if [ "${ENABLE_HY2:-0}" = "1" ]; then PROXY_TAG=auto; else PROXY_TAG=proxy; fi
  if [ "${AI_MODE:-main}" = "dedicated" ]; then AI_OUT_TAG=ai-out; else AI_OUT_TAG="$PROXY_TAG"; fi
  export PROXY_TAG AI_OUT_TAG AUTO_DETECT_INTERFACE DNS_CN DNS_REMOTE
}

# 端预设：只覆盖平台相关的两项，其余沿用 client.env
apply_target() {
  case "$1" in
    desktop) TARGET_OUT="$OUTDIR/sing-box-client-desktop.json" ;;
    android) TARGET_OUT="$OUTDIR/sing-box-client-android.json"; CLIENT_MIXED=0; AUTO_DETECT_INTERFACE=true ;;
    ios)     TARGET_OUT="$OUTDIR/sing-box-client-ios.json";     CLIENT_MIXED=0; AUTO_DETECT_INTERFACE=true ;;
  esac
}

# 渲染中途失败也别把临时目录留下
_T=""
cleanup() { [ -n "$_T" ] && rm -rf "$_T"; }
trap cleanup EXIT

# ---------- 渲染一份 ----------
render_one() {
  local out="$1" T OBJS
  T="$(mktemp -d)"
  _T="$T"
  mkdir -p "$(dirname "$out")"

  # 入站
  render_vars "$TPL_DIR/in-tun.json.tmpl" "$T/in1.json"
  if [ "${CLIENT_MIXED:-1}" = "1" ]; then
    render_vars "$TPL_DIR/in-mixed.json.tmpl" "$T/in2.json"
    join_json "$T/in1.json" "$T/in2.json" >"$T/inbounds.json"
  else
    cp "$T/in1.json" "$T/inbounds.json"
  fi

  # 出站
  render_vars "$TPL_DIR/out-reality.json.tmpl" "$T/o1.json"
  OBJS=("$T/o1.json")
  if [ "${ENABLE_HY2:-0}" = "1" ]; then
    render_vars "$TPL_DIR/out-hy2.json.tmpl" "$T/o2.json"; OBJS+=("$T/o2.json")
  fi
  if [ "${AI_MODE:-main}" = "dedicated" ]; then
    render_vars "$TPL_DIR/out-ai.json.tmpl" "$T/o3.json"; OBJS+=("$T/o3.json")
  fi
  if [ "${ENABLE_HY2:-0}" = "1" ]; then
    render_vars "$TPL_DIR/out-urltest.json.tmpl" "$T/o4.json"; OBJS+=("$T/o4.json")
  fi
  printf '    { "type": "direct", "tag": "direct", "domain_resolver": { "server": "dns-cn" } }' >"$T/o9.json"
  OBJS+=("$T/o9.json")
  join_json "${OBJS[@]}" >"$T/outbounds.json"

  # 路由 + 组装
  render_vars "$TPL_DIR/rulesets.json.tmpl" "$T/rulesets.json"
  render_vars "$TPL_DIR/rules.json.tmpl" "$T/rules.json"
  render_vars "$TPL_DIR/client.json.tmpl" "$T/client.json"
  inject_block "$T/client.json" "__INBOUNDS__" "$T/inbounds.json"
  inject_block "$T/client.json" "__OUTBOUNDS__" "$T/outbounds.json"
  inject_block "$T/client.json" "__RULESETS__" "$T/rulesets.json"
  inject_block "$T/client.json" "__RULES__" "$T/rules.json"

  if command -v jq >/dev/null 2>&1; then json_valid "$T/client.json"; fi
  sb_check "$T/client.json"
  install -m 600 "$T/client.json" "$out"
  rm -rf "$T"
  _T=""

  printf '  %-42s 入口=mixed:%s 主出口=%s AI=%s auto_iface=%s\n' \
    "$out" \
    "$([ "${CLIENT_MIXED:-1}" = "1" ] && echo 2080 || echo "-")" \
    "$PROXY_TAG" \
    "$([ "$AI_OUT_TAG" = ai-out ] && echo 独立 || echo 同主出口)" \
    "$AUTO_DETECT_INTERFACE"
}

# ---------- 主流程 ----------
validate_common

if [ "${#TARGETS[@]}" -eq 0 ]; then
  # 单份模式：完全按环境变量（保持旧行为）
  render_one "${OUT:-./sing-box-client.json}"
  cat <<EOF

导入方法
  Windows : GUI.for.SingBox / sing-box 命令行 → 导入 → 开 TUN（管理员）
  macOS   : sing-box 系 GUI → 导入 → 授权系统扩展
  Android : sing-box 官方 App → 从文件导入
  iOS     : sing-box 官方 App → 从文件导入
EOF
  exit 0
fi

log "生成 ${#TARGETS[@]} 份：${TARGETS[*]}"
for t in "${TARGETS[@]}"; do
  apply_target "$t"
  render_one "$TARGET_OUT"
done
printf '\n共 %d 份，输出目录：%s\n' "${#TARGETS[@]}" "$OUTDIR"
