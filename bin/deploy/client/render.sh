#!/usr/bin/env bash
# bin/deploy/client/render.sh —— 在【客户端机器】生成 sing-box 配置。
#
# 用法：
#   bash bin/deploy/client/render.sh client.env                    # 单份（完全按 client.env + 命令行变量）
#   bash bin/deploy/client/render.sh client.env --all              # 一次生成 desktop / android / ios 三份
#   bash bin/deploy/client/render.sh client.env desktop android    # 只生成指定端
#   bash bin/deploy/client/render.sh deploy.env --device laptop    # 服务端专用：拿该设备的凭据渲染
#   OUTDIR=./data bash bin/deploy/client/render.sh client.env --all   # 默认就是 data/
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
if [[ $# -gt 0 ]] && [[ "${1#-}" == "$1" ]]; then
  ENVFILE="$1"
  shift
fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"

usage() {
  cat <<'USAGE'
用法：
  bash bin/deploy/client/render.sh client.env                   # 单份（完全按 client.env + 命令行变量）
  bash bin/deploy/client/render.sh client.env --all             # 一次生成 desktop / android / ios
  bash bin/deploy/client/render.sh client.env desktop android   # 只生成指定端
  bash bin/deploy/client/render.sh deploy.env --device laptop   # 按设备凭据渲染（需在服务器上跑）
  OUTDIR=./data bash bin/deploy/client/render.sh client.env --all

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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ALL=1 ;;
    --device)
      shift
      [[ $# -gt 0 ]] || die "--device 后面要跟设备名"
      DEVICE="$1"
      ;;
    --device=*) DEVICE="${1#*=}" ;;
    -h | --help)
      usage
      exit 0
      ;;
    desktop | android | ios) TARGETS+=("$1") ;;
    *) die "未知参数：$1（可选：--all / --device NAME / desktop / android / ios）" ;;
  esac
  shift
done
[[ -n "${DEVICE}" ]] || DEVICE="" # 避免后面 ${DEVICE:-} 之外的引用踩到 unset
if [[ "${ALL}" == 1 ]]; then TARGETS=(desktop android ios); fi

[[ -f "${ENVFILE}" ]] || die "找不到 ${ENVFILE}，从服务器 /etc/sing-box/client.env 复制一份"

# ---------- 读环境：命令行显式传入的优先 ----------
# AI_SOCKS_* 必须在列表里：client.env 里它们是空值，不加会被 load_env 覆盖成空
_ov_names=("CLIENT_MIXED" "AI_MODE" "AUTO_DETECT_INTERFACE" "DNS_CN" "DNS_REMOTE" "ENABLE_HY2"
  "AI_SOCKS_SERVER" "AI_SOCKS_PORT" "AI_SOCKS_USER" "AI_SOCKS_PASS" "SERVER_HOST" "SERVER_IP"
  "DEFAULT_INTERFACE")
_ov_vals=()
for _i in "${!_ov_names[@]}"; do _ov_vals[_i]="${!_ov_names[_i]:-}"; done

load_env "${ENVFILE}"

for _i in "${!_ov_names[@]}"; do
  [[ -n "${_ov_vals[${_i}]}" ]] && export "${_ov_names[${_i}]}=${_ov_vals[${_i}]}"
done
unset _ov_names _ov_vals _i

: "${AI_MODE:=main}"
: "${CLIENT_MIXED:=1}"
: "${DNS_CN:=223.5.5.5}"
: "${DNS_REMOTE:=1.1.1.1}"
: "${AUTO_DETECT_INTERFACE:=true}"
OUTDIR="${OUTDIR:-data}"

# ---------- 按设备取凭据 ----------
if [[ -n "${DEVICE}" ]]; then
  [[ -f "${DEVICES_LIST}" ]] || die "--device 需要设备名单，但找不到 ${DEVICES_LIST}（在服务器上跑）"
  valid_device_name "${DEVICE}" || die "设备名不合法：${DEVICE}"
  _row="$(device_get "${DEVICE}")" || die "设备名单里没有 ${DEVICE}（bash device.sh list 看有哪些）"
  _cred="${_row%% *}"
  [[ -n "${_cred}" ]] || die "设备 ${DEVICE} 的凭据为空"
  DEVICE_PLATFORM="${_row#* }"
  export UUID="${_cred}" HY2_PASSWORD="${_cred}"
  unset _row _cred
  # 名单里记的平台就是默认目标端，除非命令行显式指定了别的
  if [[ "${#TARGETS[@]}" -eq 0 ]]; then TARGETS=("${DEVICE_PLATFORM}"); fi
fi

# ---------- 校验与派生 ----------
validate_common() {
  case "${AUTO_DETECT_INTERFACE}" in 0 | false | no | off) AUTO_DETECT_INTERFACE=false ;; *) AUTO_DETECT_INTERFACE=true ;; esac
  if [[ "${AI_MODE}" == "dedicated" ]]; then
    [[ -n "${AI_SOCKS_SERVER:-}" ]] || die "AI_MODE=dedicated 但 AI_SOCKS_SERVER 为空"
    [[ -n "${AI_SOCKS_USER:-}" ]] || die "AI_MODE=dedicated 但 AI_SOCKS_USER 为空"
  fi
  # 节点显示名：客户端里看到的就是出站 tag，所以用量信息写进 tag。
  # 只用「名字 · 用量」两段，异常时追加一个符号，避免挤占客户端列表。
  local _usage _mark
  NODE_LABEL="${NODE_LABEL:-vps}"
  _usage="$(quota_label 2>/dev/null || true)"
  [[ -n "${_usage}" ]] && NODE_LABEL="${NODE_LABEL} · ${_usage}"
  _mark="$(probe_mark 2>/dev/null || true)"
  [[ -n "${_mark}" ]] && NODE_LABEL="${NODE_LABEL} ${_mark}"

  # 路由用的标签与模板里的 tag 必须一致：
  # 单入口时 reality 出站就是这个标签；双入口时它是 urltest 组的标签，组内成员保持 proxy / proxy-hy2。
  PROXY_TAG="${NODE_LABEL}"
  if [[ "${ENABLE_HY2:-0}" == "1" ]]; then REALITY_TAG=proxy; else REALITY_TAG="${NODE_LABEL}"; fi
  if [[ "${AI_MODE:-main}" == "dedicated" ]]; then AI_OUT_TAG=ai-out; else AI_OUT_TAG="${PROXY_TAG}"; fi
  export PROXY_TAG REALITY_TAG NODE_LABEL AI_OUT_TAG AUTO_DETECT_INTERFACE DNS_CN DNS_REMOTE
  # auto_detect_interface=false 的代价：TUN 下 direct 出站的连接会按系统默认路由
  # 又走回 tun（环），表现为「连上立刻被断」。要关它就得给直连出站指定网卡。
  resolve_default_interface
  derive_self_direct
}

# 到「代理服务器自己」的流量必须直连。
# 否则开了 TUN 的机器把「连 VPS」也送进隧道，就从隧道出口又绕回这台 VPS（hairpin）：
# SSH 到服务器、curl 服务器的 443、以及 SPA 敲门包全会被搅坏，而症状看起来像「服务器挂了」。
# 写成配置里的第一条路由规则（而不是让人去改本机 route），才是通用的解法：
# Clash/Mihomo 的等价规则是 IP-CIDR,<VPS_IP>/32,DIRECT（多数 GUI 会自己加，命令行配置不会）。
derive_self_direct() {
  local ip="${SERVER_IP:-}"
  # SERVER_IP 没给就退一步用 SERVER_HOST（仅当它本身就是 IP 时；域名不在这里解析）
  case "${ip}" in '' | *[!0-9.]*) ip="" ;; esac
  if [[ -z "${ip}" ]]; then
    case "${SERVER_HOST:-}" in '' | *[!0-9.]*) : ;; *) ip="${SERVER_HOST}" ;; esac
  fi
  if [[ -z "${ip}" ]]; then
    SELF_DIRECT_RULE=""
    warn "client.env 里没有可用的 SERVER_IP，无法把「连服务器自己」设为直连"
    warn "  若本机开着 TUN，SSH 到这台 VPS 会被隧道接走（表现为 nc 能通、ssh 立刻被关）"
    return 0
  fi
  SELF_DIRECT_RULE="      { \"ip_cidr\": [\"${ip}/32\"], \"action\": \"route\", \"outbound\": \"direct\" },"
  log "直连规则：${ip}/32 → direct（避免 TUN 把到服务器的流量绕进隧道）"
}

# 端预设：只覆盖平台相关的两项，其余沿用 client.env
apply_target() {
  local pre=""
  [[ -n "${DEVICE}" ]] && pre="-${DEVICE}"
  case "$1" in
    desktop) TARGET_OUT="${OUTDIR}/sing-box-client${pre}-$1.json" ;;
    android)
      TARGET_OUT="${OUTDIR}/sing-box-client${pre}-$1.json"
      CLIENT_MIXED=0
      AUTO_DETECT_INTERFACE=true
      ;;
    ios)
      TARGET_OUT="${OUTDIR}/sing-box-client${pre}-$1.json"
      CLIENT_MIXED=0
      AUTO_DETECT_INTERFACE=true
      ;;
  esac
}

# auto_detect_interface=false 时，出站不再自动绑定物理网卡，direct 出站会按默认路由
# 又走回 tun（环）——症状是「连上立刻被断」。这时必须显式指定网卡：
# 用 DEFAULT_INTERFACE=<网卡名> 渲染，会写进 route.default_interface。
# 注意：开了 TUN 之后「默认路由」本身就是 utun，必须排除掉它再找物理网卡。
detect_physical_iface() {
  local cands=""
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      cands="$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $NF}' \
        | grep -E '^(en|bridge|pdp_ip)[0-9]+$' | head -n1)"
      ;;
    *)
      if command -v ip >/dev/null 2>&1; then
        cands="$(ip route show default 2>/dev/null | awk '
          { for (i=1;i<=NF;i++) if ($i=="dev") { iface=$(i+1); if (iface !~ /^(tun|utun|wg|ipsec|ppp|lo)/) { print iface; exit } } }')"
      fi
      ;;
  esac
  case "${cands}" in utun* | tun* | wg* | ipsec* | ppp* | lo*) cands="" ;; esac
  printf '%s' "${cands}"
}

resolve_default_interface() {
  if [[ "${AUTO_DETECT_INTERFACE}" == "true" ]]; then
    DEFAULT_IFACE_FRAGMENT=""
    return 0
  fi
  if [[ -n "${DEFAULT_INTERFACE:-}" ]]; then
    DEFAULT_IFACE_FRAGMENT="    \"default_interface\": \"${DEFAULT_INTERFACE}\","
    log "auto_detect_interface=false → route.default_interface=${DEFAULT_INTERFACE}（防止直连绕回 tun）"
    return 0
  fi
  DEFAULT_IFACE_FRAGMENT=""
  local iface
  iface="$(detect_physical_iface)"
  warn "AUTO_DETECT_INTERFACE=false 但没有指定网卡：TUN 开着时 direct 出站会绕回 tun（连上立刻被断）"
  if [[ -n "${iface}" ]]; then
    warn "  本机物理网卡是 ${iface}，加一个变量即可：DEFAULT_INTERFACE=${iface}"
  else
    warn "  在【目标机器】上重渲染并加 DEFAULT_INTERFACE=<物理网卡名>（macOS: en0，Windows: ipconfig 看）"
  fi
}

# 渲染中途失败也别把临时目录留下：mktemp_dir 已登记，退出时统一删
trap cleanup_tmp_dirs EXIT

# ---------- 渲染一份 ----------
render_one() {
  local out="$1" T OBJS
  mktemp_dir T
  mkdir -p "$(dirname "${out}")"

  # 入站。NO_TUN=1 时只出 mixed：服务器上跑测试客户端时用它，
  # 避免 TUN 抢走服务器自己的路由。
  if [[ "${NO_TUN:-0}" == "1" ]]; then
    [[ "${CLIENT_MIXED:-1}" == "1" ]] || die "NO_TUN=1 需要 CLIENT_MIXED=1（否则一个入站都没有了）"
    render_vars "${TPL_DIR}/in-mixed.json.tmpl" "${T}/inbounds.json"
  else
    render_vars "${TPL_DIR}/in-tun.json.tmpl" "${T}/in1.json"
    if [[ "${CLIENT_MIXED:-1}" == "1" ]]; then
      render_vars "${TPL_DIR}/in-mixed.json.tmpl" "${T}/in2.json"
      join_json "${T}/in1.json" "${T}/in2.json" >"${T}/inbounds.json"
    else
      cp "${T}/in1.json" "${T}/inbounds.json"
    fi
  fi

  # 出站
  render_vars "${TPL_DIR}/out-reality.json.tmpl" "${T}/o1.json"
  OBJS=("${T}/o1.json")
  if [[ "${ENABLE_HY2:-0}" == "1" ]]; then
    render_vars "${TPL_DIR}/out-hy2.json.tmpl" "${T}/o2.json"
    OBJS+=("${T}/o2.json")
  fi
  if [[ "${AI_MODE:-main}" == "dedicated" ]]; then
    render_vars "${TPL_DIR}/out-ai.json.tmpl" "${T}/o3.json"
    OBJS+=("${T}/o3.json")
  fi
  if [[ "${ENABLE_HY2:-0}" == "1" ]]; then
    render_vars "${TPL_DIR}/out-urltest.json.tmpl" "${T}/o4.json"
    OBJS+=("${T}/o4.json")
  fi
  printf '    { "type": "direct", "tag": "direct", "domain_resolver": { "server": "dns-cn" } }' >"${T}/o9.json"
  OBJS+=("${T}/o9.json")
  join_json "${OBJS[@]}" >"${T}/outbounds.json"

  # 路由 + 组装
  render_vars "${TPL_DIR}/rulesets.json.tmpl" "${T}/rulesets.json"
  render_vars "${TPL_DIR}/rules.json.tmpl" "${T}/rules.json"
  # 「连服务器自己」的直连规则：知道 IP 就插到规则第一条，不知道就空插入（占位符整行去掉）
  printf '%s' "${SELF_DIRECT_RULE:-}" >"${T}/rule-self.json"
  inject_block "${T}/rules.json" "__RULES_SELF__" "${T}/rule-self.json"
  render_vars "${TPL_DIR}/client.json.tmpl" "${T}/client.json"
  inject_block "${T}/client.json" "__INBOUNDS__" "${T}/inbounds.json"
  inject_block "${T}/client.json" "__OUTBOUNDS__" "${T}/outbounds.json"
  inject_block "${T}/client.json" "__RULESETS__" "${T}/rulesets.json"
  printf '%s' "${DEFAULT_IFACE_FRAGMENT:-}" >"${T}/iface.json"
  inject_block "${T}/client.json" "__ROUTE_DEFAULT_IFACE__" "${T}/iface.json"
  inject_block "${T}/client.json" "__RULES__" "${T}/rules.json"

  if command -v jq >/dev/null 2>&1; then json_valid "${T}/client.json"; fi
  sb_check "${T}/client.json"
  install -m 600 "${T}/client.json" "${out}"
  rm -rf "${T}"

  printf '  %-42s 入口=mixed:%s 主出口=%s AI=%s auto_iface=%s\n' \
    "${out}" \
    "$([[ "${CLIENT_MIXED:-1}" = "1" ]] && printf 2080 || printf %s -)" \
    "${PROXY_TAG}" \
    "$([[ "${AI_OUT_TAG}" = ai-out ]] && printf %s 独立 || printf %s 同主出口)" \
    "${AUTO_DETECT_INTERFACE}"
}

# ---------- 主流程 ----------
validate_common

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  # 单份模式：完全按环境变量（保持旧行为）
  render_one "${OUT:-${OUTDIR}/sing-box-client.json}"
  cat <<EOF

导入方法
  Windows : GUI.for.SingBox / sing-box 命令行 → 导入 → 开 TUN（管理员）
  macOS   : sing-box 系 GUI → 导入 → 授权系统扩展
  Android : sing-box 官方 App → 从文件导入
  iOS     : sing-box 官方 App → 从文件导入
EOF
  exit 0
fi

log "生成 ${#TARGETS[@]} 份：${TARGETS[*]}$([[ -n "${DEVICE}" ]] && printf '，设备 %s' "${DEVICE}")"
for t in "${TARGETS[@]}"; do
  apply_target "${t}"
  render_one "${TARGET_OUT}"
done
printf '\n共 %d 份，输出目录：%s\n' "${#TARGETS[@]}" "${OUTDIR}"
