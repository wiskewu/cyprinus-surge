#!/usr/bin/env bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
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
