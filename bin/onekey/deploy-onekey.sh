#!/usr/bin/env bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量由间接展开读取
# ===========================================================================
# deploy.sh，一键脚本。自动生成，勿手改。
#   重新生成：bash fragments/build/build-onekey.sh
# ===========================================================================
set -o pipefail
STEPS=(system install secrets hy2 server harden porthop)

# ---------------------------- lib.sh ----------------------------
# lib.sh —— 所有脚本共用的函数。不要单独运行，被 source。
#
# 注意：库不得修改调用方的 shell 选项。每个脚本在 source 之前自己声明
# set -euo pipefail / set -uo pipefail；这里再设一遍会把 -e（errexit）
# 强加给只想要 -u 的检查类脚本，导致某个管道返回非 0 时整个脚本静默退出。

DEPLOY_DIR="${DEPLOY_DIR:-/etc/sing-box}"
ENVFILE="${ENVFILE:-${DEPLOY_DIR}/deploy.env}"
CLIENT_ENV="${CLIENT_ENV:-${DEPLOY_DIR}/client.env}"
DEVICES_LIST="${DEVICES_LIST:-${DEPLOY_DIR}/devices.list}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="${LIB_DIR}/templates"
# 一键脚本在 bin/onekey 下运行，模板仍在 bin/deploy/templates
if [[ ! -d "${TPL_DIR}" && -d "${LIB_DIR}/../deploy/templates" ]]; then
  TPL_DIR="${LIB_DIR}/../deploy/templates"
fi

# 运行目录：sing-box 的工作目录，属主必须跟单元的实际运行用户一致
RUN_DIR="${RUN_DIR:-/var/lib/sing-box}"

# 日志、root 检查与交互组件统一由 bin/lib/common.sh 提供
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${LIB_DIR}/../lib/common.sh"

# ---- 临时目录：集中登记，脚本退出时统一清理 ----
# 直接写 TMP="$(mktemp -d)" 的话，die 或中断退出会把目录留在 /tmp。用 mktemp_dir
# 取目录，再在入口脚本里 trap cleanup_tmp_dirs EXIT。
_TMP_DIRS=()
cleanup_tmp_dirs() {
  local d
  for d in ${_TMP_DIRS[@]+"${_TMP_DIRS[@]}"}; do
    [[ -n "${d}" ]] && rm -rf "${d}"
  done
  _TMP_DIRS=()
  return 0
}
# 用法：mktemp_dir VAR —— 建目录、登记到退出清理表，结果写进 VAR。
# 不用 $(mktemp_dir) 取值：命令替换在子 shell 里跑，登记表加了也传不出来。
# 装服务要读的文件。默认 600 root:root；若 sing-box 以非 root 运行，改成
# root:<该用户的组> 640，否则重渲染一次就把加固后的可读权限盖掉，服务直接起不来。
# 服务单元的运行用户；未加固时为 root
service_user() {
  local u
  u="$(systemctl show -p User --value sing-box 2>/dev/null || true)"
  printf '%s' "${u:-root}"
}

# 配置目录权限必须与单元的运行用户一致：降权后单以 sing-box 运行，
# 目录若回到 700 root:root，服务连 chdir 都进不去。
ensure_deploy_dir() {
  local u g
  u="$(service_user)"
  install -d -m 750 "${DEPLOY_DIR}"
  if [[ "${u}" != "root" ]]; then
    g="$(id -gn "${u}" 2>/dev/null || printf 'root')"
    chown "root:${g}" "${DEPLOY_DIR}"
    chmod 750 "${DEPLOY_DIR}"
  else
    chmod 700 "${DEPLOY_DIR}"
  fi
}

# 运行目录必须归单元的实际运行用户。两个方向都会失败：以 sing-box 运行时
# 目录归 root:root；或者单元回到 root、但能力集里没有 CAP_DAC_OVERRIDE 时，
# root 进不了 sing-box 的 750 目录。两种都是 chdir 失败、服务起不来。
# 运行目录（含里面的 cache.db）必须归单元的实际运行用户。三个方向都会失败：
# 以 sing-box 运行时目录归 root:root；单元回到 root、但能力集里没有
# CAP_DAC_OVERRIDE 时，root 进不了 sing-box 的 750 目录；目录对了但里面的
# cache.db 还是上一次运行的用户，open 依旧 permission denied。所以 chown 必须递归。
ensure_run_dir() {
  local u g
  u="$(service_user)"
  install -d "${RUN_DIR}"
  if [[ "${u}" == "root" ]]; then
    g=root
    chmod 700 "${RUN_DIR}"
  else
    g="$(id -gn "${u}" 2>/dev/null || printf 'root')"
    chmod 750 "${RUN_DIR}"
  fi
  chown -R "${u}:${g}" "${RUN_DIR}"
}

install_service_file() { # $1=源文件 $2=目标路径
  local src="$1" dst="$2" user group
  install -m 600 "${src}" "${dst}"
  user="$(systemctl show -p User --value sing-box 2>/dev/null || true)"
  [[ -n "${user}" && "${user}" != "root" ]] || return 0
  group="$(id -gn "${user}" 2>/dev/null || true)"
  [[ -n "${group}" ]] || return 0
  chgrp "${group}" "${dst}" 2>/dev/null || true
  chmod 640 "${dst}" 2>/dev/null || true
  return 0
}

mktemp_dir() { # $1=变量名
  local d base
  [[ -n "${1:-}" ]] || die "mktemp_dir 需要一个变量名"
  # 每个 shell 一个基准目录，trap 里写死路径：数组可能被重设，值不会
  base="${_TMP_BASE:-}"
  if [[ -z "${base}" ]]; then
    base="$(mktemp -d "${TMPDIR:-/tmp}/cs.XXXXXXXX")"
    _TMP_BASE="${base}"
    # shellcheck disable=SC2064  # 有意在设置时展开：后面重设变量也不影响清理
    trap "rm -rf '${base}'" EXIT
  fi
  d="$(mktemp -d -p "${base}")"
  _TMP_DIRS+=("${d}")
  printf -v "$1" '%s' "${d}"
}

# 读取 KEY=VALUE 环境文件（不执行其中的命令）
# 文件不存在时返回 1 而不是退出：卸载与只读路径必须用非致命版本，
# 否则在未部署的机器上执行会静默退出。
load_env_optional() {
  local f="$1"
  [[ -f "${f}" ]] || return 1
  set -a
  # shellcheck disable=SC1090
  . "${f}"
  set +a
}

load_env() {
  local f="$1"
  [[ -f "${f}" ]] || die "找不到 ${f}"
  set -a
  # shellcheck disable=SC1090
  . "${f}"
  set +a
}

# 只替换模板里出现的 ${KEY}；值里的 & | \ 会被转义，跨 GNU/BSD sed 可用
render_vars() {
  local t="$1" o="$2" k v
  [[ -f "${t}" ]] || die "模板不存在：${t}"
  cp "${t}" "${o}"
  # shellcheck disable=SC2016  # 匹配模板里未展开的 ${VAR} 字面量
  for k in $(grep -o '\${[A-Z_][A-Z0-9_]*}' "${t}" | tr -d '${}' | sort -u); do
    v="${!k-}"
    [[ -n "${v}" ]] || die "变量 ${k} 未设置（检查 ${ENVFILE}）"
    v="$(printf '%s' "${v}" | sed -e 's/[&\\|]/\\&/g')"
    sed -i.bak "s|\${${k}}|${v}|g" "${o}" && rm -f "${o}.bak"
  done
}

# 把片段文件的原始内容塞进占位符（用 awk，避免 sed 转义地狱）
inject_block() {
  local f="$1" ph="$2" frag="$3"
  [[ -f "${frag}" ]] || die "片段不存在：${frag}"
  awk -v ph="${ph}" -v frag="${frag}" '
    index($0, ph) { while ((getline line < frag) > 0) print line; close(frag); next }
    { print }
  ' "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
}

# 用逗号拼接多个 JSON 片段
join_json() {
  local out="" f
  for f in "$@"; do
    [[ -n "${out}" ]] && out="${out},"$'\n'
    out="${out}$(cat "${f}")"
  done
  printf '%s' "${out}"
}

json_valid() {
  command -v jq >/dev/null 2>&1 || return 0 # 没有 jq 就跳过，sing-box check 仍会报语法错
  jq -e . "$1" >/dev/null 2>&1 || die "JSON 语法错误：$1（用 jq . 看一眼）"
}

sb_check() {
  if [[ -x "${SB_BIN}" ]]; then
    "${SB_BIN}" check -c "$1" || die "sing-box 拒绝该配置：$1"
    log "配置校验通过：$1"
  else
    warn "未找到 ${SB_BIN}，跳过 sing-box check"
  fi
}

# 探测 sshd 真实在监听的端口（空格分隔，升序）。
# 配置文件里的 Port 与 ssh.socket 的 Listen 都可能是「将来才会用」的值：
# ssh.socket 处于 inactive 时仍会返回 [::]:22，按它放行等于给未开放的端口开门。
# 10-system 用它决定 ufw 开哪个口，30-secrets 用它写进 deploy.env。
detect_ssh_ports() {
  local listen cand="" p
  command -v ss >/dev/null 2>&1 || return 1
  listen="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un)"

  # 1) 当前会话用的端口，它必然正在监听
  [[ -n "${SSH_CONNECTION:-}" ]] && cand="$(printf '%s' "${SSH_CONNECTION}" | awk '{print $4}')"
  # 2) sshd 进程实际监听
  cand="${cand} $(ss -tlnpH 2>/dev/null | awk '/users:\(\("sshd"/{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | paste -sd' ' -)"
  # 3) socket 激活：只有 ssh.socket 真在运行时才拿它的 Listen
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    cand="${cand} $(systemctl show ssh.socket -p Listen --value 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if ($i ~ /:[0-9]+$/) {n=split($i,a,":"); print a[n]}}' \
      | paste -sd' ' -)"
  fi

  # 统一用监听表过滤，不在表里的一律丢弃
  for p in ${cand}; do
    printf '%s\n' "${listen}" | grep -qx "${p}" && printf '%s\n' "${p}"
  done | sort -un | paste -sd' ' -
}

rand_pass() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-20}"; }

# ===== 设备名单 devices.list =====
# 格式：每行「名字 凭据 平台」，# 开头是注释。
# 一台设备一个凭据，同时当 VLESS 的 uuid 和 Hysteria2 的 password 用——
# 这样「吊销一台」就是删一行，两条入口同时失效，不会漏。
# 代价是同一个值出现在两个协议里（个人自用可接受，换来的是吊销的原子性）。
valid_device_name() { case "${1:-}" in "" | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac }

device_rows() {
  [[ -f "${DEVICES_LIST}" ]] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "${DEVICES_LIST}"
}

# device_get <名字> → 输出「凭据 平台」；不存在则返回 1
device_get() {
  local n c p
  while read -r n c p; do
    if [[ "${n}" == "$1" ]]; then
      printf '%s %s\n' "${c}" "${p:-desktop}"
      return 0
    fi
  done < <(device_rows)
  return 1
}

device_exists() { device_get "$1" >/dev/null 2>&1; }

# ---------------------------------- 分享链接
# 把同一份凭据拼成 URI，供只认分享链接的客户端用（v2rayN、mihomo、手机 App）。
# 与设备 JSON 出自同一份 devices.list 与 deploy.env，参数必须与之保持一致。

# 百分号编码：密码里可能出现 + / =
urlenc() {
  if command -v jq >/dev/null 2>&1; then
    jq -rn --arg s "$1" '$s|@uri'
    return 0
  fi
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's|/|%2F|g' -e 's/+/%2B/g' \
    -e 's/=/%3D/g' -e 's/@/%40/g' -e 's/ /%20/g'
}

# 链接里的主机：有域名时用域名（证书与 SNI 都按它签），否则用公网 IP
uri_host() {
  if [[ -n "${DOMAIN:-}" ]]; then
    printf '%s' "${DOMAIN}"
  else
    printf '%s' "${SERVER_IP:-}"
  fi
}

# VLESS REALITY：uuid 取自该设备的凭据，sni 与 pbk、sid 取自 deploy.env
uri_vless() { # $1=设备名 $2=凭据
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$2" "$(uri_host)" "${VLESS_PORT:-443}" "${REALITY_SERVER_NAME:-${REALITY_DEST:-}}" \
    "${REALITY_PUBLIC_KEY}" "${SHORT_ID}" "$(urlenc "$1")"
}

# Hysteria2：密码与该设备的 uuid 相同，带 salamander 混淆与端口跳跃区间
uri_hy2() { # $1=设备名 $2=凭据
  local hop
  [[ "${ENABLE_HY2:-0}" == "1" ]] || return 0
  hop="${HY2_HOP_RANGE:-}"
  printf 'hy2://%s@%s:%s/?sni=%s&alpn=h3&obfs=salamander&obfs-password=%s' \
    "$(urlenc "$2")" "$(uri_host)" "${HY2_PORT:-8443}" "${DOMAIN}" "$(urlenc "${OBFS_PASSWORD:-}")"
  # 区间写成 8443:8447，URI 里写 mport=8443-8447
  [[ -n "${hop}" ]] && printf '&mport=%s' "$(printf '%s' "${hop}" | tr ':' '-')"
  printf '#%s\n' "$(urlenc "$1-hy2")"
}

# 一台设备的全部链接：vless 在前，hy2 仅在其启用时输出
uri_list() { # $1=设备名
  local cred
  cred="$(device_get "$1" | awk '{print $1}')"
  [[ -n "${cred}" ]] || return 1
  uri_vless "$1" "${cred}"
  uri_hy2 "$1" "${cred}"
}

# ---------------------------------------------------------------- 用量与告警
# 当月已用流量（字节），数据源 vnstat；取不到时输出空，调用方据此省略标签
month_bytes() {
  command -v vnstat >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  vnstat --json m 2>/dev/null \
    | jq -r '[.interfaces[].traffic | ((.month // .months) // []) | .[-1] | ((.rx // 0) + (.tx // 0))] | add // 0' 2>/dev/null || true
}

# 把字节数压成 1.2G 这样的短标识
fmt_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B K M G T P", u, " "); i = 1;
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i <= 2 || b == int(b)) printf "%.0f%s", b, u[i]; else printf "%.1f%s", b, u[i];
  }'
}

# 配额的写法：允许 1T / 1024G / 纯字节
quota_bytes() {
  local q="${MONTHLY_QUOTA:-1T}"
  case "${q}" in
    *[tT]) awk -v n="${q%[tT]}" 'BEGIN { printf "%.0f", n * 1024 * 1024 * 1024 * 1024 }' ;;
    *[gG]) awk -v n="${q%[gG]}" 'BEGIN { printf "%.0f", n * 1024 * 1024 * 1024 }' ;;
    *[mM]) awk -v n="${q%[mM]}" 'BEGIN { printf "%.0f", n * 1024 * 1024 }' ;;
    *[!0-9]*) printf '' ;;
    *) printf '%s' "${q}" ;;
  esac
}

# 节点显示名用的用量标签，形如 3.6G/1T；取不到数据时输出空
quota_label() {
  local used quota
  used="$(month_bytes)"
  [[ -n "${used}" && "${used}" != "0" ]] || return 0
  quota="$(quota_bytes)"
  if [[ -n "${quota}" && "${quota}" != "0" ]]; then
    printf '%s/%s' "$(fmt_bytes "${used}")" "$(fmt_bytes "${quota}")"
  else
    printf '%s' "$(fmt_bytes "${used}")"
  fi
}

# 最近一条探针记录，但只在它足够新时才返回。
# 探针停摆时最后一行会一直留在文件里，拿着它下结论等于用过期事实报警。
probe_last_fresh() {
  local log="${PROBE_STATE_DIR:-/var/lib/sing-box-monitor}/probe.log" last ts epoch age
  [[ -r "${log}" ]] || return 0
  last="$(tail -n 1 "${log}")"
  [[ -n "${last}" ]] || return 0
  ts="${last%%,*}"
  # GNU date 与 BSD date 的写法不同；都失败就退回不过滤，不能因为解析失败就丢记录
  epoch="$(date -u -d "${ts}" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${ts}" +%s 2>/dev/null || printf '')"
  [[ -n "${epoch}" ]] || {
    printf '%s' "${last}"
    return 0
  }
  age=$(($(date +%s) - epoch))
  [[ "${age}" -le $((${PROBE_MAX_AGE_MIN:-15} * 60)) ]] || return 0
  printf '%s' "${last}"
}

# 探针异常标记：最近一条探针里服务或端口挂了、AI 出口被风控时返回一个符号。
# 只用单个符号，避免节点名过长挤占客户端显示。
probe_mark() {
  local last
  last="$(probe_last_fresh)"
  [[ -n "${last}" ]] || return 0
  case "${last}" in
    *',down,'* | *',down'*) printf '⚠' ;;
    *',403,'* | *',429,'*) printf '⚠' ;;
    *) printf '' ;;
  esac
}

# ---------------------------- 10-system.sh ----------------------------
# 步骤 10：系统初始化。函数与变量都以 system_ 前缀命名，便于一键脚本内联后不冲突。
system_TITLE="系统初始化（依赖 / BBR / swap / 时间同步 / SSH 加固 / 防火墙）"
system_OPTIONAL=0

# 读 sshd 生效值。判定与诊断走同一条路径：`sshd -T | grep -q` 会在 pipefail 下
# 因 SIGPIPE 误判，也可能在 sshd -T 瞬时失败时给出空结果；两者不一致时就会出现
# 「判定说没生效、诊断却打出正确的值」。
system_sshd_value() {
  local out
  out="$(sshd -T 2>/dev/null || true)"
  [[ -n "${out}" ]] || return 1
  printf '%s\n' "${out}" \
    | awk -v k="${1,,}" 'tolower($1) == k { print $2; exit }'
}

system_check() {
  [[ -f /etc/sysctl.d/99-proxy.conf ]] || return 1
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | grep -q '^Status: active' || return 1
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]] || return 1
  # 有可用公钥时，密码登录必须已经关掉；没有公钥则跳过不算未配置
  # （00-bootstrap 会提示先 ssh-copy-id，不该让 --status 一直报红）
  if [[ "$(system_sshd_value passwordauthentication)" != "no" ]]; then
    system_has_authorized_key && return 1
  fi
  return 0
}

# 是否至少有一个可用的公钥：没有就不许关密码，否则会把人锁在门外
system_has_authorized_key() {
  local f
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -r "${f}" ]] || continue
    grep -qE '^[[:space:]]*ssh-(rsa|ed25519|ecdsa)' "${f}" && return 0
  done
  return 1
}

# 探测 SSH 端口由 lib.sh 的 detect_ssh_ports 提供：30-secrets 也要用同一份规则
# 把真实端口写进 deploy.env，两处不能各有一套判断。

# 只留本次要放行的 SSH 规则：旧值（例如历史版本写进 deploy.env 的 22）留在
# ufw 里就是永久给一个没人监听的端口开门。只处理本脚本加的注释为 ssh 的规则。
system_prune_ssh_rules() { # $1=本次放行的端口列表
  local keep="$1" spec port
  command -v ufw >/dev/null 2>&1 || return 0
  # 同一条规则在 ufw status 里会以 v4 与 v6 两行出现，spec 相同，去重后只删一次
  while read -r spec; do
    [[ -n "${spec}" ]] || continue
    port="${spec%%/*}"
    case " ${keep} " in *" ${port} "*) continue ;; esac
    if ufw delete allow "${spec}" >/dev/null 2>&1; then
      warn "    已移除冗余 SSH 规则：${spec}（sshd 未监听，且本次未要求放行）"
    fi
  done < <(ufw status 2>/dev/null | awk -F'#' '/# *ssh[[:space:]]*$/{print $1}' | awk '{print $1}' | sort -u)
}

# deploy.env 里的 SSH_PORT 只是记录：留着非监听值会让每次重跑都重新警告一遍，
# 也会让人误以为旧端口还开着。探测到真实端口后顺手纠正。
system_sync_ssh_port() { # $1=探测到的端口列表
  local detected="$1" actual=""
  [[ -f "${ENVFILE}" ]] || return 0
  grep -q '^SSH_PORT=' "${ENVFILE}" || return 0
  [[ -n "${detected}" ]] || return 0
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    actual="$(printf '%s' "${SSH_CONNECTION}" | awk '{print $4}')"
  fi
  case " ${detected} " in *" ${actual} "*) ;; *) actual="${detected%% *}" ;; esac
  [[ -n "${actual}" ]] || return 0
  grep -qx "SSH_PORT=${actual}" "${ENVFILE}" && return 0
  sed -i.bak "s|^SSH_PORT=.*|SSH_PORT=${actual}|" "${ENVFILE}" && rm -f "${ENVFILE}.bak"
  log "    deploy.env 的 SSH_PORT 纠正为 ${actual}"
}

# 决定 ufw 要放行哪些 SSH 端口，结果写 stdout（空格分隔，升序）。
# 依据是「真的在监听」：配置文件里的 Port 或 ssh.socket 的 Listen 不代表现在能登录。
# SSH_PORT 只有用环境变量显式给出、且尚未监听时才额外放行——那是「先开新口、再改
# sshd」的过渡期。deploy.env 里的旧值（历史版本写死 22）不放行，否则等于永久给一个
# 没人监听的端口开门。
system_ssh_ports() { # $1=探测到的端口列表
  local detected="$1" ports
  if [[ -z "${detected}" ]]; then
    case "${SSH_PORT:-}" in
      '' | *[!0-9]*) printf '22' ;;
      *) printf '%s' "${SSH_PORT}" ;;
    esac
    return 0
  fi
  ports="${detected}"
  if [[ -n "${SSH_PORT:-}" ]] && ! printf '%s\n' "${detected}" | tr ' ' '\n' | grep -qx "${SSH_PORT}"; then
    if [[ "${SSH_PORT_FROM_ENV:-0}" == "1" ]]; then
      ports="$(printf '%s\n%s\n' "${detected}" "${SSH_PORT}" | sort -un | paste -sd' ' -)"
      warn "    SSH_PORT=${SSH_PORT} 尚未监听，本次一并放行（挪端口过渡期）"
    else
      warn "    SSH_PORT=${SSH_PORT} 未在监听，本次不放行；实际监听：${detected}"
      warn "    确实要开通它：ufw allow ${SSH_PORT}/tcp，或 SSH_PORT=${SSH_PORT} 重跑本步"
    fi
  fi
  printf '%s' "${ports}"
}

system_run() {
  local VLESS_PORT="${VLESS_PORT:-443}" HY2_PORT="${HY2_PORT:-8443}"
  local HY2_HOP_END="${HY2_HOP_END:-8447}" SWAP_MB="${SWAP_MB:-1024}" SSH_PORTS DETECTED_SSH_PORTS
  export DEBIAN_FRONTEND=noninteractive

  log "1/8 安装基础软件"
  apt-get update -qq
  apt-get -y -qq install --no-install-recommends \
    ca-certificates curl openssl jq tar unzip ufw fail2ban \
    unattended-upgrades vnstat mtr-tiny dnsutils >/dev/null

  log "2/8 内核参数：BBR + 大缓冲区"
  cat >/etc/sysctl.d/99-proxy.conf <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
SYSCTL
  modprobe tcp_bbr 2>/dev/null || true
  printf '%s\n' tcp_bbr >/etc/modules-load.d/bbr.conf
  sysctl --system >/dev/null

  log "3/8 出站优先 IPv4"
  touch /etc/gai.conf
  grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf || printf '%s\n' 'precedence ::ffff:0:0/96  100' >>/etc/gai.conf

  log "4/8 swap"
  if ! swapon --show | grep -q .; then
    if [[ ! -f /swapfile ]]; then
      fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_MB}" status=none
      chmod 600 /swapfile && mkswap /swapfile >/dev/null
    fi
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || printf '%s\n' '/swapfile none swap sw 0 0' >>/etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
  fi

  log "5/8 时间同步"
  timedatectl set-timezone UTC
  timedatectl set-ntp true
  systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true

  # 先改 sshd 再收防火墙：万一配置写坏了，防火墙这一步根本不会执行到，
  # 你至少还留着一条能连回来的路（且已连着的会话不受影响）
  log "6/8 SSH 加固：仅公钥登录"
  if system_has_authorized_key; then
    mkdir -p /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/99-proxy.conf <<'SSHEOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
SSHEOF
    # Ubuntu 镜像自带 50-cloud-init.conf 里写着 PasswordAuthentication yes，
    # 而 sshd 对每个关键字取「第一个出现的值」，50 排在 99 前面 → 它赢。
    # 所以必须就地改掉，不能只在 99 里写一遍。
    CI=/etc/ssh/sshd_config.d/50-cloud-init.conf
    if [[ -f "${CI}" ]] && grep -qiE '^[[:space:]]*PasswordAuthentication' "${CI}"; then
      [[ -f "${CI}.orig" ]] || cp -a "${CI}" "${CI}.orig"
      # 用 awk 改写而不是 sed -i 's///I'：I 标志是 GNU 独有，BSD sed 会报错
      awk '{ if (tolower($1) == "passwordauthentication") print "PasswordAuthentication no"; else print }' \
        "${CI}" >"${CI}.tmp" && mv "${CI}.tmp" "${CI}"
    fi
    if sshd -t 2>/dev/null; then
      # restart 失败必须显式报出来：sshd -T 读的是文件，服务没起来也会显示新值
      if ! { systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; }; then
        warn "    ssh 服务重启失败，运行中的 sshd 可能仍是旧策略"
      fi
      systemctl is-active --quiet ssh || systemctl is-active --quiet sshd \
        || warn "    sshd 不在运行，检查 systemctl status ssh"
      # 有些镜像（含部分云厂商自定义镜像）的 sshd_config 压根没有 Include 行，
      # 那我们写的 99-proxy.conf 就是死文件——drop-in 根本不会被读。
      # 补一条 Include 到文件最顶部（sshd 对同一关键字取第一个出现的值），验证不过就回滚。
      SC=/etc/ssh/sshd_config
      if ! sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' \
        && [[ -r "${SC}" ]] && ! grep -qiE '^[[:space:]]*Include[[:space:]]' "${SC}"; then
        warn "    ${SC} 里没有 Include sshd_config.d，drop-in 不会被读；补一条到文件顶部（备份 ${SC}.before-include）"
        [[ -f "${SC}.before-include" ]] || cp -a "${SC}" "${SC}.before-include"
        {
          printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf'
          cat "${SC}.before-include"
        } >"${SC}"
        if sshd -t 2>/dev/null; then
          systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        else
          warn "    补 Include 后 sshd -t 不通过，已回滚（sshd 未重启）"
          cp -a "${SC}.before-include" "${SC}"
        fi
      fi
      if [[ "$(system_sshd_value passwordauthentication)" == "no" ]]; then
        log "    已生效：passwordauthentication no"
      else
        _pwauth="$(system_sshd_value passwordauthentication || printf '读不到')"
        # 说不清楚就给人看证据：现在到底是多少、谁把它设回去的（第一个出现的值赢）
        warn "    未生效，当前生效值：${_pwauth:-读不到}，文件 ${SC}"
        warn "    设置该关键字的位置，drop-in 按文件名排序，靠前的生效："
        grep -rniE --exclude='*.orig' '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication)' \
          "${SC}" /etc/ssh/sshd_config.d 2>/dev/null | while IFS= read -r l; do warn "      ${l}"; done
        warn "    改完执行 sshd -t && systemctl restart ssh"
      fi
    else
      warn "sshd 配置有语法错，已回滚本步改动，sshd 未重启"
      rm -f /etc/ssh/sshd_config.d/99-proxy.conf
      [[ -f "${CI}.orig" ]] && mv "${CI}.orig" "${CI}"
    fi
  else
    warn "没有找到任何 authorized_keys，跳过 SSH 加固：先 ssh-copy-id 装好公钥，再重跑本步"
  fi

  log "7/8 防火墙（绝不假设 SSH 是 22）"
  DETECTED_SSH_PORTS="$(detect_ssh_ports)"
  SSH_PORTS="$(system_ssh_ports "${DETECTED_SSH_PORTS}")"
  if [[ -z "${DETECTED_SSH_PORTS}" ]]; then
    warn "    探测不到 sshd 监听端口：由 socket 激活或从控制台登录时如此"
    warn "    下面只按端口 ${SSH_PORTS} 放行。先确认它就是真实端口，否则这次 ufw 一开，下次就登不进来了："
    warn "      ss -tlnp | grep -E 'sshd|:22'　或　sshd -T | grep -i '^port'"
  fi
  system_prune_ssh_rules "${SSH_PORTS}"
  log "    SSH 端口：${SSH_PORTS}"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for p in ${SSH_PORTS}; do ufw allow "${p}/tcp" comment 'ssh' >/dev/null; done
  ufw allow "${VLESS_PORT}/tcp" comment 'reality' >/dev/null
  ufw allow "${HY2_PORT}:${HY2_HOP_END}/udp" comment 'hysteria2' >/dev/null
  ufw --force enable >/dev/null
  system_sync_ssh_port "${DETECTED_SSH_PORTS}"

  log "8/8 目录与常驻服务"
  ensure_deploy_dir
  ensure_run_dir
  install -d -m 700 /root/backups
  systemctl enable --now fail2ban vnstat >/dev/null 2>&1 || true
  log "完成：${SSH_PORTS} / ${VLESS_PORT}/tcp / ${HY2_PORT}-${HY2_HOP_END}/udp 已放行"
  warn "云厂商安全组也需放行同样端口，否则部分端口超时"
}

system_uninstall() {
  local VLESS_PORT="${VLESS_PORT:-443}" HY2_PORT="${HY2_PORT:-8443}" HY2_HOP_END="${HY2_HOP_END:-8447}"
  ufw delete allow "${VLESS_PORT}/tcp" >/dev/null 2>&1 || true
  ufw delete allow "${HY2_PORT}:${HY2_HOP_END}/udp" >/dev/null 2>&1 || true
  rm -f /etc/sysctl.d/99-proxy.conf
  rm -f /etc/ssh/sshd_config.d/99-proxy.conf
  [[ -f /etc/ssh/sshd_config.d/50-cloud-init.conf.orig ]] \
    && mv /etc/ssh/sshd_config.d/50-cloud-init.conf.orig /etc/ssh/sshd_config.d/50-cloud-init.conf
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  log "已移除本项目加的 ufw 规则、sysctl 与 SSH 加固（SSH 规则、swap、ufw 开关保持不动）"
}

# ---------------------------- 20-install.sh ----------------------------
# 步骤 20：安装 sing-box（固定版本）
install_TITLE="安装 sing-box（固定版本 + systemd）"
install_OPTIONAL=0

install_check() {
  [[ -x "${SB_BIN}" ]] || return 1
  [[ -f /etc/systemd/system/sing-box.service ]] || return 1
  return 0
}

install_run() {
  local VER="${SING_BOX_VERSION:-1.14.3}" ARCH TMP BIN URL
  command -v curl >/dev/null 2>&1 || die "缺少 curl，先跑系统初始化"
  case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  mktemp_dir TMP

  if [[ -n "${SING_BOX_PKG:-}" ]]; then
    cp "${SING_BOX_PKG}" "${TMP}/sb.tar.gz"
  else
    URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
    log "下载 sing-box ${VER} (${ARCH})"
    curl -fL --retry 3 --connect-timeout 15 -o "${TMP}/sb.tar.gz" "${URL}" \
      || die "下载失败；可手动下载后用 SING_BOX_PKG= 指定本地包"
  fi
  tar -xzf "${TMP}/sb.tar.gz" -C "${TMP}"
  BIN="$(find "${TMP}" -type f -name sing-box -perm -u+x | head -1)"
  [[ -n "${BIN}" ]] || die "压缩包里找不到 sing-box"
  install -m 0755 "${BIN}" "${SB_BIN}"

  # 单元已被 harden 改成 User=sing-box 时不要覆盖回去：重装二进制与单元策略无关，
  # 覆盖会让服务回到 root 全权限，而且与运行目录属主对不上——root 的能力集里没有
  # CAP_DAC_OVERRIDE，进不去 sing-box 的 750 目录，重启就是 chdir 失败。
  local unit=/etc/systemd/system/sing-box.service prev_user
  prev_user="$(service_user)"
  if [[ -f "${unit}" ]] && [[ "${prev_user}" != "root" ]]; then
    log "保留已有单元：以 ${prev_user} 运行，重装二进制不改动它"
  else
    cat >"${unit}" <<'UNIT'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
UNIT
  fi

  systemctl daemon-reload
  # 目录属主跟着单元的实际运行用户走，别让重装把加固后的权限改回 root
  ensure_deploy_dir
  ensure_run_dir
  log "运行目录 ${RUN_DIR} 归 $(service_user)（ls -ld ${RUN_DIR} 可复核）"
  systemctl enable sing-box >/dev/null
  log "已安装：$("${SB_BIN}" version | head -1)"
}

install_uninstall() {
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload
  rm -f "${SB_BIN}"
  rm -rf /var/lib/sing-box
  log "已移除 sing-box 二进制与 systemd 单元"
}

# ---------------------------- 30-secrets.sh ----------------------------
# 步骤 30：生成密钥与两份环境文件
secrets_TITLE="生成密钥（deploy.env / client.env / devices.list）"
secrets_OPTIONAL=0

secrets_check() {
  [[ -s "${ENVFILE}" ]] && [[ -s "${CLIENT_ENV}" ]] && [[ -s "${DEVICES_LIST}" ]]
}

# 是否换新客户端可见的密钥（REALITY 密钥对、short_id、HY2 混淆密码）。
# 参数 --rotate-secrets 优先；否则在真 TTY 上问一句，问不到（非交互）就沿用。
# 返回值：0=换新，1=沿用。
# 单独成函数是为了能在无 TTY 的环境里用桩替换来验证调用方逻辑。
secrets_decide_rotate() {
  [[ "${OPT_ROTATE_SECRETS:-0}" == "1" ]] && return 0
  [[ -z "${NONINTERACTIVE:-}" ]] || return 1
  [[ -t 0 ]] || return 1
  local ans="" ans2=""
  printf '\n%s 里已有 REALITY 密钥对与 HY2 混淆密码。\n' "${ENVFILE}" >&2
  read -r -p "沿用（已导出的客户端配置继续有效）？[Y/n]: " ans || true
  case "${ans:-y}" in
    n | N) ;;
    *) return 1 ;;
  esac
  # 换新会作废所有已分发配置，二次确认：回车、误敲都不至于把客户端全废掉
  printf '换新会更换 REALITY 密钥对、short_id 与 HY2 混淆密码，\n' >&2
  printf '已导出的客户端会全部连不上，需要逐台重新 export。\n' >&2
  read -r -p "确认换新？[y/N]: " ans2 || true
  case "${ans2:-n}" in
    y | Y) return 0 ;;
    *) return 1 ;;
  esac
}

secrets_run() {
  local SERVER_IP="${SERVER_IP}"
  ensure_deploy_dir
  : "${REALITY_DEST:=www.apple.com}"
  : "${DOMAIN:=}"
  : "${ENABLE_HY2:=0}"
  : "${AI_MODE:=main}"

  if [[ -n "${SERVER_IP:-}" ]]; then
    :
  else
    SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "${SERVER_IP}" ]] || SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  [[ -n "${SERVER_IP}" ]] || die "无法识别公网 IPv4，请用 SERVER_IP=x.x.x.x 指定"

  if [[ -z "${NONINTERACTIVE:-}" ]]; then
    printf '\n可直接回车使用方括号里的默认值。\n'
    local _in
    read -r -p "伪装站点 REALITY_DEST [${REALITY_DEST}]（需支持 TLS1.3+H2）: " _in
    REALITY_DEST="${_in:-${REALITY_DEST}}"
    read -r -p "入口域名 DOMAIN [${DOMAIN:-留空}]（留空则客户端连公网 IP；启用 Hysteria2 时必填）: " _in
    DOMAIN="${_in:-${DOMAIN}}"
    if [[ -n "${DOMAIN}" ]]; then
      read -r -p "启用 Hysteria2？[Y/n]: " _in
      case "${_in:-y}" in y | Y) ENABLE_HY2=1 ;; *) ENABLE_HY2=0 ;; esac
    else
      ENABLE_HY2=0
    fi
    read -r -p "第一台设备的名字 [main]: " _in
    FIRST_DEVICE="${_in:-main}"
  else
    FIRST_DEVICE="${FIRST_DEVICE:-main}"
  fi
  valid_device_name "${FIRST_DEVICE}" || die "设备名不合法：${FIRST_DEVICE}（只允许字母数字 . _ -）"

  # REALITY 公钥、short_id 与 HY2 混淆密码都嵌在已经导出的客户端配置里。换掉
  # 它们等于作废所有客户端，而错误只在客户端表现为 REALITY 校验失败或 QUIC
  # 握手失败。默认沿用 deploy.env 里的旧值；换新要用参数 --rotate-secrets，
  # 交互模式下每次都会问一句，不静默决定。
  local old_priv="" old_pub="" old_sid="" old_obfs="" reuse_reality=1
  if [[ "${OPT_ROTATE_SECRETS:-0}" != "1" ]] && [[ -f "${ENVFILE}" ]]; then
    old_priv="$(sed -n 's/^REALITY_PRIVATE_KEY=//p' "${ENVFILE}" | head -1)"
    old_pub="$(sed -n 's/^REALITY_PUBLIC_KEY=//p' "${ENVFILE}" | head -1)"
    old_sid="$(sed -n 's/^SHORT_ID=//p' "${ENVFILE}" | head -1)"
    old_obfs="$(sed -n 's/^OBFS_PASSWORD=//p' "${ENVFILE}" | head -1)"
  fi
  if [[ -n "${old_priv}" ]] && [[ -n "${old_pub}" ]] && [[ -n "${old_sid}" ]]; then
    # 沿用与否都改变已分发配置的可用性，交互时问一句，不静默决定
    secrets_decide_rotate && reuse_reality=0
  else
    reuse_reality=0
  fi
  if [[ "${reuse_reality}" == "1" ]]; then
    REALITY_PRIVATE_KEY="${old_priv}"
    REALITY_PUBLIC_KEY="${old_pub}"
    SHORT_ID="${old_sid}"
    log "沿用已有 REALITY 密钥对、short_id 与 HY2 混淆密码（换新：--rotate-secrets，之后所有设备需重新 export）"
  else
    KP="$("${SB_BIN}" generate reality-keypair)"
    REALITY_PRIVATE_KEY="$(printf '%s\n' "${KP}" | awk -F': *' '/PrivateKey/{print $2}')"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "${KP}" | awk -F': *' '/PublicKey/{print $2}')"
    SHORT_ID="$(openssl rand -hex 4)"
    [[ -n "${REALITY_PRIVATE_KEY}" ]] && [[ -n "${REALITY_PUBLIC_KEY}" ]] || die "REALITY 密钥生成失败"
  fi
  if [[ "${reuse_reality}" == "1" ]] && [[ -n "${old_obfs}" ]]; then
    OBFS_PASSWORD="${old_obfs}"
  else
    OBFS_PASSWORD="$(rand_pass 20)"
  fi

  # 设备名单已存在就原样保留：凭据不该因为重跑 secrets 而全变一遍。
  # 现有实例里的 devices.list 优先，Force 重跑也不覆盖。
  if [[ ! -s "${DEVICES_LIST}" ]]; then
    umask 077
    cat >"${DEVICES_LIST}" <<LIST
# ssh-sp 设备名单 —— 每行「名字 凭据 平台」，删一行 = 吊销那台设备（两条入口同时失效）
# 凭据同时当 VLESS 的 uuid 和 Hysteria2 的 password 用，保证吊销是原子的
${FIRST_DEVICE} $("${SB_BIN}" generate uuid) desktop
LIST
    chmod 600 "${DEVICES_LIST}"
    log "已创建设备名单：${DEVICES_LIST}（第一台：${FIRST_DEVICE}）"
  else
    log "设备名单已存在，保留：${DEVICES_LIST}"
  fi

  # client.env 里的 UUID / HY2_PASSWORD 是 devices.list 首行的镜像，
  # 让「在客户端机器上手动渲染单份」的老用法继续可用；日常以 devices.list 为准。
  local first_cred
  first_cred="$(device_get "${FIRST_DEVICE}" 2>/dev/null | awk '{print $1}')" \
    || first_cred="$(device_rows | head -1 | awk '{print $2}')"
  [[ -n "${first_cred}" ]] || die "设备名单读不出凭据：${DEVICES_LIST}"

  # 节点地址：域名优先，留空就用公网 IP
  SERVER_HOST="${DOMAIN}"
  [[ -n "${SERVER_HOST}" ]] || SERVER_HOST="${SERVER_IP}"

  # SSH_PORT 只写真实端口。写成 ${SSH_PORT:-22} 这样的占位默认值，会让防火墙步骤
  # 把 22 当成「用户额外要求放行的端口」，即使 sshd 早已不在 22 上监听。
  local ssh_port="${SSH_PORT:-}"
  [[ -n "${ssh_port}" ]] || ssh_port="$(detect_ssh_ports 2>/dev/null | awk '{print $1}')"

  umask 077
  cat >"${ENVFILE}" <<ENV
# ===== 服务器环境（含私钥，勿外传）=====
SERVER_IP=${SERVER_IP}
SSH_PORT=${ssh_port}
VLESS_PORT=${VLESS_PORT:-443}
REALITY_DEST=${REALITY_DEST}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
SHORT_ID=${SHORT_ID}

ENABLE_HY2=${ENABLE_HY2}
DOMAIN=${DOMAIN}
HY2_PORT=${HY2_PORT:-8443}
HY2_HOP_RANGE=${HY2_HOP_RANGE:-8443:8447}
HY2_UP_MBPS=${HY2_UP_MBPS:-100}
HY2_DOWN_MBPS=${HY2_DOWN_MBPS:-300}
OBFS_PASSWORD=${OBFS_PASSWORD}

# 桌面端默认 true：TUN 开着时，auto_detect_interface 负责把出站绑定到物理网卡，
# 否则 direct 出站会按默认路由又走回 tun（环），表现为「连上立刻被断」。
# 只有在 Windows 多网卡报 "not valid in its context" 时才关掉，并且要同时指定
# 网卡（客户端脚本支持 DEFAULT_INTERFACE=en0 之类）。
AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-true}
AI_MODE=${AI_MODE}
AI_SOCKS_SERVER=${AI_SOCKS_SERVER:-}
AI_SOCKS_PORT=${AI_SOCKS_PORT:-1080}
AI_SOCKS_USER=${AI_SOCKS_USER:-}
AI_SOCKS_PASS=${AI_SOCKS_PASS:-}
CLIENT_MIXED=${CLIENT_MIXED:-1}
ENV

  cat >"${CLIENT_ENV}" <<ENV
# ===== 客户端环境（单份渲染时用；多设备请在服务端用 device.sh 直接生成）=====
SERVER_IP=${SERVER_IP}
SERVER_HOST=${SERVER_HOST}
VLESS_PORT=${VLESS_PORT:-443}
REALITY_SERVER_NAME=${REALITY_DEST}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
UUID=${first_cred}

ENABLE_HY2=${ENABLE_HY2}
DOMAIN=${DOMAIN}
HY2_PORT=${HY2_PORT:-8443}
HY2_HOP_RANGE=${HY2_HOP_RANGE:-8443:8447}
HY2_PASSWORD=${first_cred}
OBFS_PASSWORD=${OBFS_PASSWORD}

# 桌面端默认 true：TUN 开着时，auto_detect_interface 负责把出站绑定到物理网卡，
# 否则 direct 出站会按默认路由又走回 tun（环），表现为「连上立刻被断」。
# 只有在 Windows 多网卡报 "not valid in its context" 时才关掉，并且要同时指定
# 网卡（客户端脚本支持 DEFAULT_INTERFACE=en0 之类）。
AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-true}
AI_MODE=${AI_MODE}
AI_SOCKS_SERVER=${AI_SOCKS_SERVER:-}
AI_SOCKS_PORT=${AI_SOCKS_PORT:-1080}
AI_SOCKS_USER=${AI_SOCKS_USER:-}
AI_SOCKS_PASS=${AI_SOCKS_PASS:-}
CLIENT_MIXED=${CLIENT_MIXED:-1}
ENV
  chmod 600 "${ENVFILE}" "${CLIENT_ENV}" "${DEVICES_LIST}"
  # root:root 在真实服务器上有效；某些环境（如容器）没这个组，失败也不影响 0600 权限
  chown root:root "${ENVFILE}" "${CLIENT_ENV}" 2>/dev/null || true

  log "已生成：${ENVFILE} / ${CLIENT_ENV} / ${DEVICES_LIST}"
  printf '\n  服务器 IP    %s\n  节点地址     %s%s\n  端口         %s/tcp\n  伪装站点     %s\n  设备数       %s\n  REALITY 公钥 %s\n  short_id     %s\n' \
    "${SERVER_IP}" "${SERVER_HOST}" "$([ "${SERVER_HOST}" = "${SERVER_IP}" ] && printf '（未配域名）' || printf '（域名）')" \
    "${VLESS_PORT:-443}" "${REALITY_DEST}" "$(device_rows | wc -l)" "${REALITY_PUBLIC_KEY}" "${SHORT_ID}"
}

secrets_uninstall() {
  if [[ "${PURGE:-0}" == "1" ]]; then
    rm -f "${ENVFILE}" "${CLIENT_ENV}" "${DEVICES_LIST}"
    log "已删除 deploy.env / client.env / devices.list"
  else
    log "保留 deploy.env / client.env / devices.list（如需删除：--purge）"
  fi
}

# ---------------------------- 35-hy2.sh ----------------------------
# 步骤 35（可选）：Hysteria2 证书
#
# 排在 server 之前：渲染服务端配置时要读 cert.pem / key.pem，缺证书就得停下来。
# 排在 secrets 之后：域名与 ENABLE_HY2 由 secrets 写进 deploy.env，本步骤自己再读一次。
hy2_TITLE="可选：Hysteria2 证书（ACME DNS-01）"
hy2_OPTIONAL=1

hy2_check() {
  [[ -s "${DEPLOY_DIR}/cert.pem" ]] && [[ -s "${DEPLOY_DIR}/key.pem" ]] || return 1
  grep -q '^ENABLE_HY2=1' "${ENVFILE}" 2>/dev/null || return 1
  return 0
}

hy2_run() {
  local ACME _dom="${DOMAIN:-}" _hy2="${ENABLE_HY2:-}"
  # 驱动是先攒计划再执行，本轮 secrets 刚写进 deploy.env 的 DOMAIN / ENABLE_HY2
  # 传不进这个子 shell，必须自己读一遍，否则会在发证时再问一次域名。
  # 命令行显式给的值优先，与驱动启动时的覆盖规则一致。
  load_env_optional "${ENVFILE}" || true
  [[ -n "${_dom}" ]] && DOMAIN="${_dom}"
  [[ -n "${_hy2}" ]] && ENABLE_HY2="${_hy2}"
  # 与 port-hop 一致：没启用就直接跳过，不要往下走到交互提问
  if [[ "${ENABLE_HY2:-0}" != "1" ]]; then
    warn "ENABLE_HY2=0，跳过 Hysteria2"
    return 0
  fi
  : "${DOMAIN:=}"
  : "${CF_TOKEN:=}"
  : "${ACME_EMAIL:=}"
  if [[ -z "${DOMAIN}" ]] || [[ -z "${CF_TOKEN}" ]] || [[ -z "${ACME_EMAIL}" ]]; then
    if [[ -n "${NONINTERACTIVE:-}" ]]; then
      warn "缺少 DOMAIN/CF_TOKEN/ACME_EMAIL，跳过 Hysteria2"
      return 0
    fi
    # 没有终端就只能报错：直接 read 会因 stdin 已关闭而静默失败在 set -e 下
    if [[ ! -t 0 ]]; then
      die "缺少 DOMAIN/CF_TOKEN/ACME_EMAIL，且当前不是交互终端；补齐后重跑或用 NONINTERACTIVE=1 跳过"
    fi
    [[ -n "${DOMAIN}" ]] || read -r -p "域名（例如 vps.example.com）: " DOMAIN
    [[ -n "${ACME_EMAIL}" ]] || read -r -p "邮箱（证书到期通知）: " ACME_EMAIL
    [[ -n "${CF_TOKEN}" ]] || read -r -p "Cloudflare API Token: " CF_TOKEN
  fi
  [[ -n "${DOMAIN}" ]] && [[ -n "${ACME_EMAIL}" ]] && [[ -n "${CF_TOKEN}" ]] || die "DOMAIN / ACME_EMAIL / CF_TOKEN 不能为空"

  ensure_deploy_dir
  command -v acme.sh >/dev/null 2>&1 || {
    log "安装 acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL}" >/dev/null
  }
  ACME="${HOME}/.acme.sh/acme.sh"
  export CF_Token="${CF_TOKEN}"
  log "用 DNS-01 签发 ${DOMAIN}"
  # acme.sh 在「域名未变、还没到续期时间」时会打印 Domains not changed / Skipping
  # 并返回非 0。那不是失败，后面照常把已有证书装到 ${DEPLOY_DIR}。
  local issue_log issue_rc=0 T
  mktemp_dir T
  issue_log="${T}/acme-issue.log"
  "${ACME}" --issue --dns dns_cf -d "${DOMAIN}" --server letsencrypt --keylength ec-256 \
    >"${issue_log}" 2>&1 || issue_rc=$?
  cat "${issue_log}" 2>/dev/null || true
  if [[ "${issue_rc}" -eq 0 ]]; then
    log "签发完成"
  elif grep -qE 'Domains not changed|Skip' "${issue_log}" 2>/dev/null; then
    log "证书仍在有效期，跳过签发"
  else
    warn "签发失败：确认 A 记录已生效（Cloudflare 需灰云）后重跑"
    warn "    继续尝试安装 acme.sh 里已有的证书"
  fi
  # reloadcmd 用 try-restart：本步骤现在跑在 server 之前，此时还没有 config.json，
  # 直接 restart 会失败并被 acme.sh 当成「证书安装失败」。续期时服务在跑，照常重启。
  "${ACME}" --install-cert -d "${DOMAIN}" --ecc \
    --fullchain-file "${DEPLOY_DIR}/cert.pem" \
    --key-file "${DEPLOY_DIR}/key.pem" \
    --reloadcmd "systemctl try-restart sing-box 2>/dev/null || true" || die "安装证书失败"
  # acme.sh 直接写目标路径，权限是 600 root:root。降权运行时 sing-box 读不到，
  # 这里补一次组读，规则与 install_service_file 一致。
  svc_user="$(systemctl show -p User --value sing-box 2>/dev/null || true)"
  chmod 600 "${DEPLOY_DIR}/cert.pem" "${DEPLOY_DIR}/key.pem"
  if [[ -n "${svc_user}" && "${svc_user}" != "root" ]] && group="$(id -gn "${svc_user}" 2>/dev/null)"; then
    chgrp "${group}" "${DEPLOY_DIR}/cert.pem" "${DEPLOY_DIR}/key.pem" 2>/dev/null || true
    chmod 640 "${DEPLOY_DIR}/cert.pem" "${DEPLOY_DIR}/key.pem" 2>/dev/null || true
  fi

  for f in "${ENVFILE}" "${CLIENT_ENV}"; do
    [[ -f "${f}" ]] || continue
    sed -i.bak "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|; s|^ENABLE_HY2=.*|ENABLE_HY2=1|" "${f}" && rm -f "${f}.bak"
  done
  log "证书就绪，ENABLE_HY2=1 已写入环境文件"
}

hy2_uninstall() {
  rm -f "${DEPLOY_DIR}/cert.pem" "${DEPLOY_DIR}/key.pem"
  for f in "${ENVFILE}" "${CLIENT_ENV}"; do
    [[ -f "${f}" ]] || continue
    sed -i.bak "s|^ENABLE_HY2=.*|ENABLE_HY2=0|" "${f}" && rm -f "${f}.bak"
  done
  log "已删除证书并把 ENABLE_HY2 置 0"
}

# ---------------------------- 40-server.sh ----------------------------
# 步骤 40：渲染服务端配置并启动
server_TITLE="渲染服务端配置并启动（双入口）"
server_OPTIONAL=0

server_check() {
  [[ -s "${DEPLOY_DIR}/config.json" ]] || return 1
  systemctl is-active --quiet sing-box 2>/dev/null || return 1
  return 0
}

# 把设备名单渲染成 sing-box 的 users 数组内容（逗号分隔，不含外层方括号）。
# 模板里写 "users": [[ __USERS__ ]]，方括号由模板负责。
# $1=名单内容 $2=凭据字段名(uuid|password) $3=输出文件
render_users() {
  local rows="$1" field="$2" out="$3" n c p first=1
  : >"${out}"
  while read -r n c p; do
    [[ -n "${first}" ]] || printf ',\n' >>"${out}"
    if [[ "${field}" == uuid ]]; then
      printf '        { "name": "%s", "uuid": "%s", "flow": "xtls-rprx-vision" }' "${n}" "${c}" >>"${out}"
    else
      printf '        { "name": "%s", "password": "%s" }' "${n}" "${c}" >>"${out}"
    fi
    first=""
  done <<<"${rows}"
  [[ -n "${first}" ]] && die "设备名单解析不出条目：${DEVICES_LIST}"
  return 0
}

server_run() {
  local T
  load_env "${ENVFILE}"
  export CERT_DIR="${CERT_DIR:-${DEPLOY_DIR}}"
  [[ -x "${SB_BIN}" ]] || die "sing-box 未安装"
  mktemp_dir T

  # users 数组按设备名单渲染：一份设备名单 = 一组凭据，删一行就吊销那台
  local rows
  rows="$(device_rows)"
  [[ -n "${rows}" ]] || die "设备名单为空：${DEVICES_LIST}"

  render_vars "${TPL_DIR}/in-reality.json.tmpl" "${T}/in1.json"
  render_users "${rows}" uuid "${T}/u1.json"
  inject_block "${T}/in1.json" "__USERS__" "${T}/u1.json"
  cp "${T}/in1.json" "${T}/inbounds.json"
  if [[ "${ENABLE_HY2:-0}" == "1" ]]; then
    for f in cert.pem key.pem; do
      [[ -s "${DEPLOY_DIR}/${f}" ]] || die "缺少 ${DEPLOY_DIR}/${f}：先跑 bash deploy.sh --only hy2 签发证书，或把 deploy.env 里的 ENABLE_HY2 改成 0 后重跑 server"
    done
    render_vars "${TPL_DIR}/in-hy2.json.tmpl" "${T}/in2.json"
    render_users "${rows}" password "${T}/u2.json"
    inject_block "${T}/in2.json" "__USERS__" "${T}/u2.json"
    join_json "${T}/in1.json" "${T}/in2.json" >"${T}/inbounds.json"
    log "双入口：REALITY:${VLESS_PORT} + Hysteria2:${HY2_PORT}/udp（$(printf '%s\n' "${rows}" | wc -l) 台设备）"
  else
    log "单入口：REALITY:${VLESS_PORT}（$(printf '%s\n' "${rows}" | wc -l) 台设备）"
  fi

  # 规则集缓存：没有 cache_file 时每次重启都要重新下载 .srs，弱网下冷启动直接失败
  export CACHE_FILE="${SING_BOX_CACHE_FILE:-/var/lib/sing-box/cache.db}"
  render_vars "${TPL_DIR}/server.json.tmpl" "${T}/server.json"
  inject_block "${T}/server.json" "__INBOUNDS__" "${T}/inbounds.json"
  # cache_file 必须放在 experimental 里：1.13 起顶层写法被移除，写成顶层会直接
  # 报 unknown field "cache_file" 并拒绝启动。
  local exp_frag="${T}/experimental.json"
  printf '%s\n' "    \"cache_file\": { \"enabled\": true, \"path\": \"${CACHE_FILE}\" }" >"${exp_frag}"
  inject_block "${T}/server.json" "__EXPERIMENTAL__" "${exp_frag}"
  json_valid "${T}/server.json"
  sb_check "${T}/server.json"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    # 预览也走 data/：脚本目录是入库的，往里写会把服务端配置（含 REALITY 私钥）带进版本控制
    local out="${OUT:-data/config.preview.json}"
    mkdir -p "$(dirname "${out}")"
    cp "${T}/server.json" "${out}"
    log "DRY_RUN：已生成 ${out}"
    return 0
  fi
  install_service_file "${T}/server.json" "${DEPLOY_DIR}/config.json"
  # 重启前把运行目录（含 cache.db）归到单元的实际运行用户：单元被 install 或
  # harden 改过运行用户时，上一轮的 cache.db 属主就跟不上了，启动直接 open 失败。
  ensure_run_dir
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || {
    # 只贴本次重启前后的日志：默认 -n 30 会把几小时前的握手噪音一起打出来，
    # 真因（比如 chdir / cache.db permission denied）反而被冲掉
    journalctl -u sing-box -n 30 --no-pager --since "-2 min" || true
    warn "运行目录与配置目录现状（属主必须与单元的运行用户一致）："
    stat -c '%A %U:%G %n' "${RUN_DIR}" "${DEPLOY_DIR}" 2>&1 | sed 's/^/    /' >&2 || true
    find "${RUN_DIR}" -maxdepth 1 -printf '%M %u:%g %p\n' 2>/dev/null | head -5 | sed 's/^/    /' >&2 || true
    die "sing-box 没起来（单元 User=$(service_user)）"
  }
  log "服务已启动"
}

server_uninstall() {
  systemctl stop sing-box >/dev/null 2>&1 || true
  rm -f "${DEPLOY_DIR}/config.json"
  log "已停止服务并删除 config.json（密钥与证书保留）"
}

# ---------------------------- 55-harden.sh ----------------------------
# 步骤 55：sing-box 降权与 systemd 沙箱。
#
# 独立入口 bin/deploy/one/harden.sh 复用本文件的函数，两条路径行为一致。
# 放在 hy2 与 server 之后：沙箱化后要验证 Hy2 端口，证书与服务端配置都就位时 8443 才会监听。
harden_TITLE="sing-box 降权与 systemd 沙箱"
harden_OPTIONAL=0

HARDEN_UNIT="${HARDEN_UNIT:-/etc/systemd/system/sing-box.service}"
HARDEN_UNIT_ORIG="${HARDEN_UNIT}.orig"
SB_USER="${SB_USER:-sing-box}"
HARDEN_PROFILE="${HARDEN_PROFILE:-full}"

harden_env() {
  load_env_optional "${ENVFILE}" || true
  VLESS_PORT="${VLESS_PORT:-443}"
  HY2_PORT="${HY2_PORT:-8443}"
  ENABLE_HY2="${ENABLE_HY2:-0}"
}

harden_unit_has() { grep -qE "^$1=" "${HARDEN_UNIT}" 2>/dev/null; }

harden_check() {
  systemctl is-active --quiet sing-box || return 1
  harden_unit_has NoNewPrivileges || return 1
  grep -qE '^User=sing-box' "${HARDEN_UNIT}" 2>/dev/null
}

harden_running_user() {
  local pid
  pid="$(pgrep -x sing-box 2>/dev/null | head -n1 || true)"
  [[ -n "${pid}" ]] || {
    printf '未运行'
    return 0
  }
  ps -o user= -p "${pid}" | tr -d ' '
}

harden_report() {
  printf '%s\t%s\n' '单元文件' "${HARDEN_UNIT}"
  printf '%s\t%s\n' '服务状态' "$(systemctl is-active sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' 'FragmentPath' "$(systemctl show -p FragmentPath --value sing-box 2>/dev/null || printf '未加载')"
  printf '%s\t%s\n' 'DropInPaths' "$(systemctl show -p DropInPaths --value sing-box 2>/dev/null || printf '无')"
  printf '%s\t%s\n' '生效 User' "$(systemctl show -p User --value sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' '生效 ReadWritePaths' "$(systemctl show -p ReadWritePaths --value sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' '单元 User' "$(grep -oE '^User=.*' "${HARDEN_UNIT}" 2>/dev/null | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' 'StateDirectory' "$(grep -oE '^StateDirectory=.*' "${HARDEN_UNIT}" 2>/dev/null | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' '运行用户' "$(harden_running_user)"
  printf '%s\t%s\n' '沙箱' "$(harden_unit_has ProtectSystem && printf '完整' || printf '仅降权')"
  printf '%s\t%s\n' 'NoNewPrivileges' "$(harden_unit_has NoNewPrivileges && printf 'yes' || printf '未设置')"
  printf '%s\t%s\n' 'ProtectSystem' "$(harden_unit_has ProtectSystem && grep -oE '^ProtectSystem=.*' "${HARDEN_UNIT}" | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' 'CapabilityBoundingSet' "$(harden_unit_has CapabilityBoundingSet && grep -oE '^CapabilityBoundingSet=.*' "${HARDEN_UNIT}" | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' '备份' "$([[ -f "${HARDEN_UNIT_ORIG}" ]] && printf '%s' "${HARDEN_UNIT_ORIG}" || printf '无')"
}

harden_port_listening() { # $1=tcp|udp $2=端口
  if [[ "$1" == tcp ]]; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  else
    ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  fi
}

harden_verify_running() {
  # 服务 active 不等于端口已绑定：sing-box 起来后还要几十到几百毫秒才 listen，
  # 只查一次会把「还在绑定」误判成失败，进而回滚。
  local _wait=0
  while [[ "${_wait}" -lt 40 ]]; do
    if systemctl is-active --quiet sing-box && harden_port_listening tcp "${VLESS_PORT}"; then
      if [[ "${ENABLE_HY2}" == "1" ]]; then
        harden_port_listening udp "${HY2_PORT}" && return 0
      else
        return 0
      fi
    fi
    sleep 0.5
    _wait=$((_wait + 1))
  done
  printf '端口现状：\n' >&2
  ss -tlnH 2>/dev/null | awk '{print "  tcp " $4}' >&2 || true
  ss -ulnH 2>/dev/null | awk '{print "  udp " $4}' >&2 || true
  return 1
}

# 回滚后单元以 root 运行，而运行目录此时归 sing-box、权限 750，root 落到「其他人」，
# chdir 会被拒。恢复单元前先把属主交回 root。
harden_restore_run_dir_owner() {
  [[ -d /var/lib/sing-box ]] || return 0
  chown -R root:root /var/lib/sing-box
  chmod 700 /var/lib/sing-box
}

harden_rollback() {
  warn "回滚到 ${HARDEN_UNIT_ORIG}"
  harden_restore_run_dir_owner || warn "运行目录属主未改回 root，检查 /var/lib/sing-box"
  cp -a "${HARDEN_UNIT_ORIG}" "${HARDEN_UNIT}"
  systemctl daemon-reload
  systemctl restart sing-box || true
  sleep 1
  if systemctl is-active --quiet sing-box; then
    log "已恢复原单元与 /var/lib/sing-box 属主，服务运行中"
  else
    warn "原单元也没起来，问题不在沙箱。最近日志："
    journalctl -u sing-box -n 20 --no-pager 2>&1 | sed 's/^/    /' >&2 || true
    warn "下一步：bash bin/deploy/one/install-singbox.sh 重建单元，再 systemctl restart sing-box"
  fi
}

harden_write_unit() { # $1=full|minimal
  local profile="${1:-full}"
  cat >"${HARDEN_UNIT}" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=${SB_USER}
Group=${SB_USER}
ExecStart=${SB_BIN} -D /var/lib/sing-box -c ${DEPLOY_DIR}/config.json run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitMEMLOCK=infinity
UMask=0077
# 运行目录由 systemd 建好并 chown 给 User，避免手改属主漏掉
StateDirectory=sing-box
StateDirectoryMode=0750

# ---- 能力：只保留监听低端口、操作 nftables/路由、创建 TUN 所需的三项 ----
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
EOF

  # minimal：到此为止。沙箱指令起不来时先用这一档，确认降权本身没问题
  if [[ "${profile}" == "minimal" ]]; then
    cat >>"${HARDEN_UNIT}" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${HARDEN_UNIT}"
    return 0
  fi

  cat >>"${HARDEN_UNIT}" <<'EOF'

# ---- 文件系统与内核面 ----
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/sing-box
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictSUIDSGID=yes
RemoveIPC=yes

# ---- 进程自身 ----
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${HARDEN_UNIT}"
}

harden_run() {
  harden_env
  [[ -x "${SB_BIN}" ]] || die "找不到 ${SB_BIN}，先跑 install 步骤"
  [[ -s "${DEPLOY_DIR}/config.json" ]] || die "缺少 ${DEPLOY_DIR}/config.json，先跑 server 步骤"
  command -v systemctl >/dev/null 2>&1 || die "本步骤按 systemd 写"

  log "1/4 准备 system 用户 ${SB_USER}"
  if id -u "${SB_USER}" >/dev/null 2>&1; then
    log "    已存在"
  else
    useradd --system --no-create-home --shell /usr/sbin/nologin "${SB_USER}"
    log "    已创建"
  fi

  # 先停干净：服务若还在 auto-restart 循环，后面的 restart 可能让旧单元先跑一轮，
  # 而旧单元以 root 运行、目录此时已归 sing-box，chdir 会失败。
  log "2/4 停服务并收权限：${DEPLOY_DIR} 归 root:${SB_USER}，目录 750、文件 640"
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl reset-failed sing-box >/dev/null 2>&1 || true
  chown -R "root:${SB_USER}" "${DEPLOY_DIR}"
  find "${DEPLOY_DIR}" -type d -exec chmod 750 {} +
  find "${DEPLOY_DIR}" -type f -exec chmod 640 {} +
  # install 步骤用 install -d -m 700 建的是 root:root，这里必须显式改属主，
  # 否则降权后 sing-box 连 chdir 都进不去
  install -d -m 750 /var/lib/sing-box
  chown -R "${SB_USER}:${SB_USER}" /var/lib/sing-box
  chmod 750 /var/lib/sing-box
  # 重启前先确认目标用户真能进去，别让服务再重启几十次
  if command -v runuser >/dev/null 2>&1; then
    if ! runuser -u "${SB_USER}" -- test -x /var/lib/sing-box; then
      ls -ld /var/lib/sing-box >&2
      namei -l /var/lib/sing-box >&2 || true
      die "${SB_USER} 进不去 /var/lib/sing-box，属主或父目录权限不对，先看上面的 ls 与 namei 输出"
    fi
    runuser -u "${SB_USER}" -- test -r "${DEPLOY_DIR}/config.json" \
      || die "${SB_USER} 读不到 ${DEPLOY_DIR}/config.json，检查属主与 640"
  fi

  log "3/4 写入单元（${HARDEN_UNIT}，模式 ${HARDEN_PROFILE}）"
  if [[ -f "${HARDEN_UNIT}" ]] && ! harden_unit_has NoNewPrivileges; then
    cp -a "${HARDEN_UNIT}" "${HARDEN_UNIT_ORIG}"
    log "    原单元备份到 ${HARDEN_UNIT_ORIG}"
  fi
  harden_write_unit "${HARDEN_PROFILE}"
  systemctl daemon-reload

  log "4/4 重启并自检"
  systemctl start sing-box
  if ! systemctl is-active --quiet sing-box; then
    # 首次启动偶发 chdir EACCES：清掉失败状态再起一次
    warn "首次启动未成，清状态后重试一次"
    systemctl reset-failed sing-box >/dev/null 2>&1 || true
    systemctl start sing-box
  fi
  if harden_verify_running; then
    if [[ "${ENABLE_HY2}" == "1" ]]; then
      log "sing-box 以 ${SB_USER} 运行，端口 ${VLESS_PORT}/tcp 与 ${HY2_PORT}/udp 正常"
    else
      log "sing-box 以 ${SB_USER} 运行，端口 ${VLESS_PORT}/tcp 正常"
    fi
    return 0
  fi
  journalctl -u sing-box -n 30 --no-pager >&2 || true
  {
    printf '调试信息：\n'
    ls -ld /var/lib/sing-box "${DEPLOY_DIR}" 2>&1
    id "${SB_USER}" 2>&1
  } >&2
  [[ -f "${HARDEN_UNIT_ORIG}" ]] && harden_rollback
  die "服务未就绪，已回滚。先看上方 journal 里的 status=：226/NAMESPACE 是命名空间限制，203/EXEC 是权限或路径，1 加 permission denied 是文件权限。确认降权本身没问题就先用 HARDEN_PROFILE=minimal 重跑 --only harden"
}

harden_uninstall() {
  if [[ -f "${HARDEN_UNIT_ORIG}" ]]; then
    harden_restore_run_dir_owner || warn "运行目录属主未改回 root，检查 /var/lib/sing-box"
    cp -a "${HARDEN_UNIT_ORIG}" "${HARDEN_UNIT}"
    rm -f "${HARDEN_UNIT_ORIG}"
    systemctl daemon-reload
    systemctl restart sing-box >/dev/null 2>&1 || true
    log "已恢复原单元，sing-box 回到 root 运行"
  else
    log "没有 ${HARDEN_UNIT_ORIG}，单元保持现状"
  fi
}

# ---------------------------- 60-porthop.sh ----------------------------
# 步骤 60（可选）：Hysteria2 端口跳跃
#
# 持久化方式：自建 systemd oneshot 单元，开机执行 iptables 规则。
# 不用 iptables-persistent：Debian 里 ufw 声明了
# Breaks: iptables-persistent, netfilter-persistent，装它会连带把 ufw 卸掉，
# 防火墙随之失效。见 06-ops.html 的说明。
porthop_TITLE="可选：Hysteria2 端口跳跃（iptables 重定向）"
porthop_OPTIONAL=1
PORTHOP_HELPER="/usr/local/sbin/sing-box-porthop"
PORTHOP_UNIT="/etc/systemd/system/sing-box-porthop.service"

porthop_rule_args() {
  PORTHOP_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  PORTHOP_START="${HY2_PORT:-8443}"
  PORTHOP_END="${HY2_HOP_RANGE##*:}"
  [[ -n "${PORTHOP_IFACE}" ]] || return 1
  return 0
}

porthop_check() {
  command -v iptables >/dev/null 2>&1 || return 1
  porthop_rule_args || return 1
  iptables -t nat -C PREROUTING -i "${PORTHOP_IFACE}" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "${PORTHOP_START}" 2>/dev/null
}

porthop_write_helper() {
  cat >"${PORTHOP_HELPER}" <<EOF
#!/bin/sh
# 由 60-porthop.sh 生成，勿手改。systemd 单元 sing-box-porthop.service 调用它。
set -eu
IFACE="${PORTHOP_IFACE}"
START="${PORTHOP_START}"
END="${PORTHOP_END}"
case "\$1" in
  apply)
    iptables -t nat -C PREROUTING -i "\${IFACE}" -p udp --dport "\${START}:\${END}" -j REDIRECT --to-ports "\${START}" 2>/dev/null ||
      iptables -t nat -A PREROUTING -i "\${IFACE}" -p udp --dport "\${START}:\${END}" -j REDIRECT --to-ports "\${START}"
    ;;
  clear)
    iptables -t nat -D PREROUTING -i "\${IFACE}" -p udp --dport "\${START}:\${END}" -j REDIRECT --to-ports "\${START}" 2>/dev/null || true
    ;;
  *)
    printf '用法：%s apply|clear\n' "\$0" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 "${PORTHOP_HELPER}"
}

porthop_write_unit() {
  cat >"${PORTHOP_UNIT}" <<EOF
[Unit]
Description=sing-box Hysteria2 port hop (udp ${PORTHOP_START}:${PORTHOP_END} to ${PORTHOP_START})
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${PORTHOP_HELPER} apply
ExecStop=${PORTHOP_HELPER} clear

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${PORTHOP_UNIT}"
}

porthop_warn_conflict() {
  if dpkg -l iptables-persistent >/dev/null 2>&1 && [[ "$(dpkg -l iptables-persistent | awk '/^ii/{print $1}')" == "ii" ]]; then
    warn "检测到 iptables-persistent。ufw 声明 Breaks: iptables-persistent，两者不能共存"
    warn "  已装它的话 ufw 会被 apt 卸掉。改用本脚本的 systemd 单元后可以移除："
    warn "    sudo apt-get purge -y iptables-persistent netfilter-persistent"
    warn "    sudo apt-get install -y ufw"
  fi
  return 0
}

porthop_run() {
  load_env_optional "${ENVFILE}" || true
  [[ "${ENABLE_HY2:-0}" == "1" ]] || {
    warn "ENABLE_HY2=0，跳过端口跳跃"
    return 0
  }
  porthop_rule_args || die "识别不到默认网卡"
  porthop_warn_conflict

  porthop_write_helper
  porthop_write_unit
  systemctl daemon-reload
  systemctl enable sing-box-porthop >/dev/null 2>&1 || true
  systemctl restart sing-box-porthop >/dev/null 2>&1 || true
  if porthop_check; then
    log "端口跳跃生效：udp ${PORTHOP_START}:${PORTHOP_END} → ${PORTHOP_START}（${PORTHOP_IFACE}）"
    log "已持久化：systemd 单元 sing-box-porthop.service，开机自动应用"
  else
    journalctl -u sing-box-porthop -n 10 --no-pager >&2 || true
    die "规则未生效，见上方单元日志"
  fi
}

porthop_uninstall() {
  systemctl disable --now sing-box-porthop >/dev/null 2>&1 || true
  rm -f "${PORTHOP_UNIT}" "${PORTHOP_HELPER}"
  systemctl daemon-reload
  porthop_rule_args || return 0
  iptables -t nat -D PREROUTING -i "${PORTHOP_IFACE}" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "${PORTHOP_START}" 2>/dev/null || true
  log "已移除端口跳跃规则与 systemd 单元"
}

# ============================================================================
# 驱动：由 build-onekey.sh 拼接到 deploy.sh 末尾。不要单独执行本文件。
# ============================================================================
OPT_REUSE=0
OPT_OVERWRITE=0
OPT_YES=0
OPT_DRY=0
OPT_UNINSTALL=0
OPT_REINSTALL=0
OPT_STATUS=0
OPT_ROTATE_SECRETS=0
ONLY=""
SKIP=""
INTERACTIVE=1
PURGE=0

usage() {
  cat <<'USAGE'
用法：sudo bash deploy.sh [选项]

不带选项 → 交互模式：先扫描每一步的状态，再逐个询问「复用 / 覆盖 / 跳过」。

  --reuse            已配置的步骤直接复用（不提问）
  --overwrite        已配置的步骤重新执行并覆盖
  --only a,b         只跑指定步骤（system,install,secrets,hy2,server,harden,porthop）
  --skip a,b         跳过指定步骤
  --yes              全部确认，不再提问
  --dry-run          只打印计划，不执行
  --status           只看状态
  --uninstall        卸载（保留 deploy.env / 证书）
  --purge            卸载并删除 deploy.env / 证书
  --reinstall        卸载并重装（等价 --purge 后全量 --overwrite）
  --rotate-secrets   重建密钥时换掉所有客户端可见的密钥：REALITY 密钥对、
                     short_id 与 HY2 混淆密码。已导出的客户端配置立即失效
                     （默认沿用，交互模式会再确认一次）
  -h, --help         显示本帮助

环境变量（也可直接传给脚本）：
  SSH_PORT  REALITY_DEST  DOMAIN  ENABLE_HY2  SING_BOX_VERSION
  CF_TOKEN  ACME_EMAIL  SERVER_IP  AUTO_DETECT_INTERFACE
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reuse) OPT_REUSE=1 ;;
      --overwrite) OPT_OVERWRITE=1 ;;
      --yes)
        OPT_YES=1
        INTERACTIVE=0
        # 步骤内部也按这个判断要不要提问：只关掉驱动自己的确认不够，
        # secrets / hy2 仍会 read，非交互跑就会卡住或读空
        NONINTERACTIVE=1
        export NONINTERACTIVE
        ;;
      --dry-run) OPT_DRY=1 ;;
      --uninstall) OPT_UNINSTALL=1 ;;
      --purge) PURGE=1 ;;
      --reinstall)
        OPT_REINSTALL=1
        PURGE=1
        ;;
      --rotate-secrets) OPT_ROTATE_SECRETS=1 ;;
      --status)
        OPT_DRY=1
        OPT_YES=1
        OPT_STATUS=1
        ;;
      --only)
        shift
        ONLY="${1:-}"
        ;;
      --only=*) ONLY="${1#*=}" ;;
      --skip)
        shift
        SKIP="${1:-}"
        ;;
      --skip=*) SKIP="${1#*=}" ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "未知参数：$1（--help 看用法）" ;;
    esac
    shift
  done
}

hy2_enabled() { [[ "${ENABLE_HY2:-0}" == "1" ]] || grep -q '^ENABLE_HY2=1' "${ENVFILE}" 2>/dev/null; }

step_title() {
  local v="${1}_TITLE"
  printf '%s' "${!v:-$1}"
}
step_optional() {
  local v="${1}_OPTIONAL"
  printf '%s' "${!v:-0}"
}
step_state() { if "${1}_check" >/dev/null 2>&1; then printf '已配置\n'; else printf '未配置\n'; fi; }

selected() {
  local id="$1"
  if [[ -n "${ONLY}" ]]; then case ",${ONLY}," in *",${id},"*) ;; *) return 1 ;; esac fi
  if [[ -n "${SKIP}" ]]; then case ",${SKIP}," in *",${id},"*) return 1 ;; esac fi
  return 0
}

print_plan() {
  printf '\n%-10s %-8s %-6s %s\n' "步骤" "状态" "可选" "说明"
  printf '%s\n' "--------------------------------------------------------------"
  local id
  for id in "${STEPS[@]}"; do
    selected "${id}" || {
      printf '%-10s %-8s %-6s %s（按参数排除）\n' "${id}" "-" "-" "$(step_title "${id}")"
      continue
    }
    printf '%-10s %-8s %-6s %s\n' "${id}" "$(step_state "${id}")" "$([ "$(step_optional "${id}")" = 1 ] && printf yes || printf no)" "$(step_title "${id}")"
  done
  printf '%s\n\n' "--------------------------------------------------------------"
}

# 返回码：0=覆盖重跑，1=复用，2=跳过
decide() {
  local id="$1" a
  [[ "${OPT_OVERWRITE}" == 1 ]] && return 0
  [[ "${OPT_REUSE}" == 1 ]] && return 1
  [[ "${INTERACTIVE}" == 0 ]] && return 1
  printf '  [%s] 已配置（%s）\n      (r) 复用已存在配置  (o) 覆盖重跑  (s) 跳过   [r] ' "${id}" "$(step_title "${id}")"
  read -r a
  case "${a:-r}" in
    r | R) return 1 ;;
    o | O) return 0 ;;
    *) return 2 ;;
  esac
}

execute() {
  local id="$1"
  log "===== ${id}：$(step_title "${id}") ====="
  if [[ "${OPT_DRY}" == 1 ]]; then
    log "DRY_RUN：跳过执行"
    return 0
  fi
  # 子 shell + errexit：单步失败不会带崩整个流程
  (
    set -eo pipefail
    "${id}_run"
  )
}

# device.sh 与本脚本的相对位置：仓库内它与 deploy.sh 同目录（bin/deploy），一键脚本在
# bin/onekey/，设备脚本在 ../deploy/。找不到就只给文件名，不猜绝对路径。
device_script_path() {
  local dir
  for dir in "${SELF_DIR:-}" "$(cd "$(dirname "$0")" 2>/dev/null && pwd)"; do
    [[ -n "${dir}" ]] || continue
    if [[ -f "${dir}/device.sh" ]]; then
      printf '%s' "${dir}/device.sh"
      return 0
    fi
    if [[ -f "${dir}/../deploy/device.sh" ]]; then
      printf '%s' "$(cd "${dir}/../deploy" && pwd)/device.sh"
      return 0
    fi
  done
  printf 'device.sh'
}

# 已导出的客户端配置是否还对得上服务器的 REALITY 密钥与 HY2 混淆密码。
# 对不上时客户端只会报 reality verification failed，服务端日志是
# REALITY: processed invalid connection，现场很难联想到是 secrets 轮换过密钥。
# 这里在部署结束时主动点出来，而不是等人到客户端上排查。
warn_stale_clients() {
  local dir="${DEPLOY_DIR}/clients" f pub sid obfs stale=()
  command -v jq >/dev/null 2>&1 || return 0
  [[ -d "${dir}" ]] || return 0
  [[ -n "${REALITY_PUBLIC_KEY:-}" ]] || return 0
  for f in "${dir}"/sing-box-client-*.json; do
    [[ -f "${f}" ]] || continue
    read -r pub sid obfs <<<"$(jq -r '[
        ([.outbounds[]? | select(.tls.reality.public_key) | .tls.reality.public_key][0] // ""),
        ([.outbounds[]? | select(.tls.reality.short_id) | .tls.reality.short_id][0] // ""),
        ([.outbounds[]? | select(.type == "hysteria2") | .obfs.password][0] // "")
      ] | @tsv' "${f}" 2>/dev/null | tr '\t' ' ')"
    [[ -n "${pub}" ]] || continue
    if [[ "${pub}" != "${REALITY_PUBLIC_KEY}" || "${sid}" != "${SHORT_ID:-}" ]] \
      || [[ -n "${obfs}" && -n "${OBFS_PASSWORD:-}" && "${obfs}" != "${OBFS_PASSWORD}" ]]; then
      stale+=("$(basename "${f}" .json | sed -E 's/^sing-box-client-//; s/-(desktop|android|ios)$//')")
    fi
  done
  [[ "${#stale[@]}" -gt 0 ]] || return 0
  warn "以下设备的客户端配置与服务器当前密钥不一致，连不上（客户端报 reality verification failed）："
  warn "    $(printf '%s\n' "${stale[@]}" | sort -u | paste -sd' ' -)"
  warn "    重新导出：sudo bash $(device_script_path) export <设备名>"
}

print_next_steps() {
  local dev
  [[ -f "${ENVFILE}" ]] || return 0
  load_env_optional "${ENVFILE}" || true
  dev="$(device_script_path)"
  warn_stale_clients
  printf '\n下一步\n'
  printf '  当前设备：%s\n' "$(device_rows | awk '{print $1}' | paste -sd' ' -)"
  printf '  新增设备：sudo bash %s add <名字> [desktop|android|ios]\n' "${dev}"
  printf '  导出这一台的配置：sudo bash %s export <名字>\n' "${dev}"
  printf '  换凭据：sudo bash %s rotate <名字>　　吊销：sudo bash %s revoke <名字>\n' "${dev}" "${dev}"
  printf '  客户端导入后验收：bash bin/deploy/client/verify.sh\n'
}

# 开局把这次要跑的东西与需要准备的材料讲清楚：缺料在非交互运行下直接退出 2，
# 交互下只提示，真正缺的时候由对应步骤提问。取值来自环境变量与 deploy.env。
preflight() {
  local missing=() want_hy2=0
  [[ "${OPT_STATUS}" == "1" ]] && return 0
  load_env_optional "${ENVFILE}" || true
  # 只在 hy2 确实会执行时要求材料：--skip hy2,porthop 或 ENABLE_HY2=0 都不需要
  if selected hy2 && hy2_enabled; then want_hy2=1; fi

  printf '\n本次需要用到的材料\n'
  printf '  - REALITY_DEST（伪装站点）：%s\n' "${REALITY_DEST:-www.apple.com（默认）}"
  printf '  - DOMAIN（入口域名，启用 Hysteria2 时必填）：%s\n' "${DOMAIN:-未给出}"
  printf '  - Cloudflare API Token（编辑区域 DNS 权限）：%s\n' "$([[ -n "${CF_TOKEN:-}" ]] && printf '已给出' || printf '未给出')"
  printf '  - ACME 邮箱（证书到期通知）：%s\n' "${ACME_EMAIL:-未给出}"
  printf '  - Cloudflare A 记录：域名指向本机，代理关闭（灰云）\n'
  printf '  - 客户端可见密钥（REALITY 密钥对 / short_id / HY2 混淆密码）：%s\n' \
    "$([[ "${OPT_ROTATE_SECRETS}" == "1" ]] && printf '按 --rotate-secrets 换新' || printf '默认沿用已有值，交互时再确认')"
  printf '\n'

  [[ "${want_hy2}" == "1" ]] || return 0
  local k
  for k in DOMAIN CF_TOKEN ACME_EMAIL; do
    if [[ -z "${!k:-}" ]] && ! grep -q "^${k}=." "${ENVFILE}" 2>/dev/null; then
      missing+=("${k}")
    fi
  done
  [[ "${#missing[@]}" -gt 0 ]] || return 0
  warn "启用 Hysteria2 需要的值还没给：${missing[*]}"
  [[ "${INTERACTIVE}" == 1 ]] && return 0
  usage_error "非交互运行缺少 ${missing[*]}；补齐后重跑，或用 --skip hy2,porthop 跳过 Hysteria2"
}

do_install() {
  local id rc run_ok=0 run_fail=0
  local -a todo=()
  for id in "${STEPS[@]}"; do
    selected "${id}" || continue
    if [[ "$(step_state "${id}")" == "已配置" ]]; then
      decide "${id}"
      rc=$?
      case "${rc}" in
        1)
          log "复用 ${id}（不执行）"
          continue
          ;;
        2)
          log "跳过 ${id}"
          continue
          ;;
      esac
    fi
    todo+=("${id}")
  done

  if [[ "${#todo[@]}" -eq 0 ]]; then
    log "没有需要执行的步骤"
    return 0
  fi
  # 可选步骤现在是否启用还不定：ENABLE_HY2 可能要到 secrets 步骤才写进 deploy.env。
  # 计划里用 ? 标出这类步骤，执行前再按 deploy.env 决定跳不跳。
  local -a todo_show=() opt_wait=0
  for id in "${todo[@]}"; do
    if [[ "$(step_optional "${id}")" == 1 ]] && ! hy2_enabled; then
      todo_show+=("${id}?")
      opt_wait=1
    else
      todo_show+=("${id}")
    fi
  done
  log "将执行：${todo_show[*]}"
  [[ "${opt_wait}" == 0 ]] || log "带 ? 的步骤只在 ENABLE_HY2=1 时执行（secrets 步骤里开启也算）"
  if [[ "${INTERACTIVE}" == 1 ]] && [[ "${OPT_DRY}" == 0 ]]; then
    printf '确认开始？[Y/n] '
    local a
    read -r a
    case "${a:-y}" in y | Y) ;; *)
      log "已取消"
      exit 1
      ;;
    esac
  fi
  for id in "${todo[@]}"; do
    # 可选步骤是否执行由 deploy.env 的 ENABLE_HY2 决定，而这份文件可能本轮才被
    # secrets 写入。计划阶段就过滤会把刚开启的 Hysteria2 静默跳过，留到执行前再判。
    if [[ "$(step_optional "${id}")" == 1 ]] && ! hy2_enabled; then
      log "跳过 ${id}（ENABLE_HY2 未开启）"
      continue
    fi
    if execute "${id}"; then run_ok=$((run_ok + 1)); else
      run_fail=$((run_fail + 1))
      warn "步骤 ${id} 失败"
      # 失败后直接给单步重试的命令：改完环境或重传脚本后不用再把 7 步跑一遍
      warn "    单步重试（该步会自动修好目录属主等前置状态）：bash $0 --only ${id} --overwrite --yes"
      if [[ "${INTERACTIVE}" == 1 ]]; then
        printf '继续后面的步骤？[y/N] '
        local a
        read -r a
        case "${a:-n}" in y | Y) ;; *) die "中止：${id} 失败" ;; esac
      else
        die "中止：${id} 失败"
      fi
    fi
  done
  printf '\n完成：%d 个步骤成功，%d 个失败\n' "${run_ok}" "${run_fail}"
  [[ "${run_fail}" -eq 0 ]] || exit 1
  print_next_steps
}

do_uninstall() {
  local id
  load_env_optional "${ENVFILE}" || true
  if [[ "${OPT_DRY}" == 1 ]]; then
    log "DRY_RUN：将卸载 ${STEPS[*]}"
    return 0
  fi
  if [[ "${INTERACTIVE}" == 1 ]] && [[ "${OPT_YES}" == 0 ]]; then
    printf '\n将卸载以下内容：\n  - sing-box 服务与二进制、systemd 单元\n  - ufw 里本项目加的 443/8443-8447 规则、sysctl 优化\n'
    [[ "${PURGE}" == 1 ]] && printf '  - deploy.env / client.env / 证书（--purge）\n'
    printf '确认？[y/N] '
    local a
    read -r a
    case "${a:-n}" in y | Y) ;; *)
      log "已取消"
      return 0
      ;;
    esac
  fi
  for ((i = ${#STEPS[@]} - 1; i >= 0; i--)); do
    id="${STEPS[i]}"
    if "${id}_check" >/dev/null 2>&1; then
      log "卸载 ${id}"
      (
        set -eo pipefail
        "${id}_uninstall"
      ) || warn "${id} 卸载不完整（可手工检查）"
    fi
  done
  if [[ "${PURGE}" == 1 ]]; then
    rm -rf "${DEPLOY_DIR}"
    log "已删除 ${DEPLOY_DIR}"
    rmdir /root/deploy 2>/dev/null || true
  else
    log "保留 ${DEPLOY_DIR}（含密钥与证书，便于下次复用）"
  fi
  log "卸载结束。SSH 防火墙规则、swap、ufw 开关均未改动。"
}

main() {
  trap cleanup_tmp_dirs EXIT
  parse_args "$@"
  local _d="${DOMAIN:-}" _h="${ENABLE_HY2:-}" _r="${REALITY_DEST:-}" _s="${SERVER_IP:-}" _p="${SSH_PORT:-}"
  # shellcheck disable=SC1090  # 路径来自变量，由调用方保证
  [[ -f "${ENVFILE}" ]] && . "${ENVFILE}" 2>/dev/null || true
  [[ -n "${_d}" ]] && DOMAIN="${_d}"
  [[ -n "${_h}" ]] && ENABLE_HY2="${_h}"
  [[ -n "${_r}" ]] && REALITY_DEST="${_r}"
  [[ -n "${_s}" ]] && SERVER_IP="${_s}"
  # 命令行给的 SSH_PORT 优先于 deploy.env；同时标记来源，system 步骤据此区分
  # 「挪端口的过渡放行」与「deploy.env 里的旧值」，后者不放行。
  if [[ -n "${_p}" ]]; then
    SSH_PORT="${_p}"
    SSH_PORT_FROM_ENV=1
    export SSH_PORT_FROM_ENV
  fi

  if [[ "${OPT_REINSTALL}" == 1 ]]; then
    OPT_UNINSTALL=1
    do_uninstall
    OPT_UNINSTALL=0
    OPT_OVERWRITE=1
    OPT_REUSE=0
    log "重新安装：全量覆盖"
  fi

  if [[ "${OPT_UNINSTALL}" == 1 ]]; then
    do_uninstall
    return 0
  fi

  print_plan
  preflight
  # --dry-run 与 --status 的语义都是只看计划，打印完即返回，不进入执行阶段
  [[ "${OPT_DRY}" == 1 ]] && return 0

  [[ "${OPT_DRY}" == 1 ]] || need_root
  if [[ ! -f /etc/debian_version ]]; then
    warn "本脚本只在 Debian / Ubuntu 上验证过，当前系统可能不兼容"
  fi

  [[ -n "${ENABLE_HY2:-}" ]] || ENABLE_HY2=0
  do_install
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
