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
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="${SELF_DIR}/templates"

log() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

need_root() {
  [[ "${SKIP_ROOT:-0}" == "1" ]] && return 0
  [[ "$(id -u)" == "0" ]] || die "需要 root：sudo bash $0"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1，请先跑 00-bootstrap.sh"
}

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

mktemp_dir() {
  local _d
  [[ -n "${1:-}" ]] || die "mktemp_dir 需要一个变量名"
  _d="$(mktemp -d)"
  _TMP_DIRS+=("${_d}")
  printf -v "$1" '%s' "${_d}"
}

# 读取 KEY=VALUE 环境文件（不执行其中的命令）
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
