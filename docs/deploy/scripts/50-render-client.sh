#!/usr/bin/env bash
# 50-render-client.sh —— 在【客户端机器】生成 sing-box 配置。
#
# 用法：
#   bash 50-render-client.sh client.env                    # 单份（完全按 client.env + 命令行变量）
#   bash 50-render-client.sh client.env --all              # 一次生成 desktop / android / ios 三份
#   bash 50-render-client.sh client.env desktop android    # 只生成指定端
#   bash 50-render-client.sh deploy.env --device laptop    # 服务端专用：拿该设备的凭据渲染
#   OUTDIR=./data bash 50-render-client.sh client.env --all   # 默认就是 data/
#
# --device 从 devices.list 取该设备的凭据并覆盖 UUID / HY2_PASSWORD，
# 输出文件名带设备名。应在【服务器】上跑（devices.list 在那边），生成好的 JSON 再分发。
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
  bash 50-render-client.sh deploy.env --device laptop   # 按设备凭据渲染（需在服务器上跑）
  OUTDIR=./data bash 50-render-client.sh client.env --all

单份模式：OUT=... 或默认 data/sing-box-client.json，所有变量由你决定。
多端模式：内置预设覆盖平台相关项（CLIENT_MIXED / AUTO_DETECT_INTERFACE），其余来自 client.env。
          桌面若报 not valid in its context，在前面加 AUTO_DETECT_INTERFACE=false。
产物一律落在 OUTDIR（默认 ./data，已在 .gitignore 里），不要往脚本目录写。
--device ：从 devices.list 取该设备凭据覆盖 UUID/HY2_PASSWORD，文件名带设备名。
USAGE
}

# ---------- 解析参数 ----------
TARGETS=()
ALL=0
DEVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    --device) shift; [ $# -gt 0 ] || die "--device 后面要跟设备名"; DEVICE="$1" ;;
    --device=*) DEVICE="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    desktop|android|ios) TARGETS+=("$1") ;;
    *) die "未知参数：$1（可选：--all / --device NAME / desktop / android / ios）" ;;
  esac
  shift
done
[ -n "$DEVICE" ] || DEVICE=""     # 避免后面 ${DEVICE:-} 之外的引用踩到 unset
if [ "$ALL" = 1 ]; then TARGETS=(desktop android ios); fi

[ -f "$ENVFILE" ] || die "找不到 ${ENVFILE}（从服务器 /etc/sing-box/client.env 复制过来）"

# ---------- 读环境：命令行显式传入的优先 ----------
# AI_SOCKS_* 必须在列表里：client.env 里它们是空值，不加会被 load_env 覆盖成空
_ov_names=("CLIENT_MIXED" "AI_MODE" "AUTO_DETECT_INTERFACE" "DNS_CN" "DNS_REMOTE" "ENABLE_HY2" \
           "AI_SOCKS_SERVER" "AI_SOCKS_PORT" "AI_SOCKS_USER" "AI_SOCKS_PASS" "SERVER_HOST")
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
OUTDIR="${OUTDIR:-data}"

# ---------- 按设备取凭据 ----------
if [ -n "$DEVICE" ]; then
  [ -f "$DEVICES_LIST" ] || die "--device 需要设备名单，但找不到 $DEVICES_LIST（在服务器上跑）"
  valid_device_name "$DEVICE" || die "设备名不合法：$DEVICE"
  _row="$(device_get "$DEVICE")" || die "设备名单里没有 $DEVICE（bash device.sh list 看有哪些）"
  _cred="${_row%% *}"
  [ -n "$_cred" ] || die "设备 $DEVICE 的凭据为空"
  DEVICE_PLATFORM="${_row#* }"
  export UUID="$_cred" HY2_PASSWORD="$_cred"
  unset _row _cred
  # 名单里记的平台就是默认目标端，除非命令行显式指定了别的
  if [ "${#TARGETS[@]}" -eq 0 ]; then TARGETS=("$DEVICE_PLATFORM"); fi
fi

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
  local pre=""
  [ -n "$DEVICE" ] && pre="-$DEVICE"
  case "$1" in
    desktop) TARGET_OUT="$OUTDIR/sing-box-client${pre}-$1.json" ;;
    android) TARGET_OUT="$OUTDIR/sing-box-client${pre}-$1.json"; CLIENT_MIXED=0; AUTO_DETECT_INTERFACE=true ;;
    ios)     TARGET_OUT="$OUTDIR/sing-box-client${pre}-$1.json";     CLIENT_MIXED=0; AUTO_DETECT_INTERFACE=true ;;
  esac
}

# 渲染中途失败也别把临时目录留下
_T=""
# 末尾那句 [ -n ... ] 在 _T 为空时返回 1，会把脚本的 exit code 变成 1，
# 所以 cleanup 必须自己 return 0
cleanup() { [ -n "${_T:-}" ] && rm -rf "$_T"; return 0; }
trap cleanup EXIT

# ---------- 渲染一份 ----------
render_one() {
  local out="$1" T OBJS
  T="$(mktemp -d)"
  _T="$T"
  mkdir -p "$(dirname "$out")"

  # 入站。NO_TUN=1 时只出 mixed：服务器上跑测试客户端时用它，
  # 避免 TUN 抢走服务器自己的路由。
  if [ "${NO_TUN:-0}" = "1" ]; then
    [ "${CLIENT_MIXED:-1}" = "1" ] || die "NO_TUN=1 需要 CLIENT_MIXED=1（否则一个入站都没有了）"
    render_vars "$TPL_DIR/in-mixed.json.tmpl" "$T/inbounds.json"
  else
    render_vars "$TPL_DIR/in-tun.json.tmpl" "$T/in1.json"
    if [ "${CLIENT_MIXED:-1}" = "1" ]; then
      render_vars "$TPL_DIR/in-mixed.json.tmpl" "$T/in2.json"
      join_json "$T/in1.json" "$T/in2.json" >"$T/inbounds.json"
    else
      cp "$T/in1.json" "$T/inbounds.json"
    fi
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
  render_one "${OUT:-$OUTDIR/sing-box-client.json}"
  cat <<EOF

导入方法
  Windows : GUI.for.SingBox / sing-box 命令行 → 导入 → 开 TUN（管理员）
  macOS   : sing-box 系 GUI → 导入 → 授权系统扩展
  Android : sing-box 官方 App → 从文件导入
  iOS     : sing-box 官方 App → 从文件导入
EOF
  exit 0
fi

log "生成 ${#TARGETS[@]} 份：${TARGETS[*]}$([ -n "$DEVICE" ] && echo "（设备 $DEVICE）")"
for t in "${TARGETS[@]}"; do
  apply_target "$t"
  render_one "$TARGET_OUT"
done
printf '\n共 %d 份，输出目录：%s\n' "${#TARGETS[@]}" "$OUTDIR"
