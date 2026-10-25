#!/usr/bin/env bash
# shellcheck disable=SC2034  # 变量供 source 本文件的脚本使用
# 管理内网脚本的共用函数。被 wg-server.sh / wg-client.sh / wg-selfcheck.sh source，
# 不单独运行，也不修改调用方的 shell 选项。
log() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

need_root() {
  [[ "${SKIP_ROOT:-0}" == 1 ]] && return 0
  [[ "$(id -u)" == 0 ]] || die "需要 root：sudo bash $0"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1"; }

WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_IF="${WG_IF:-wg0}"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
WG_PORT="${WG_PORT:-443}"
WG_ADDR="${WG_ADDR:-10.66.0.1/24}"
WG_NET="${WG_ADDR%/*}"
# 管理网段，供客户端 AllowedIPs 与自检使用；只支持 /24
[[ "${WG_ADDR##*/}" == 24 ]] || die "WG_ADDR 只支持 /24 网段：${WG_ADDR}"
WG_CIDR="$(printf '%s.0/24' "$(printf '%s' "${WG_NET}" | cut -d. -f1-3)")"

# sshd 实际监听端口，不看配置假设是 22
ssh_port() {
  local p=""
  if command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" { print $2; exit }')"
  fi
  [[ -n "${p}" ]] || p="${SSH_PORT:-22}"
  printf '%s' "${p}"
}

wg_up() { ip link show "${WG_IF}" >/dev/null 2>&1; }

# 下次分配的客户端地址：网段最后一个八位组里取最小的空闲值
next_client_ip() {
  local base="${WG_NET%.*}" used ip
  used="$(wg show "${WG_IF}" allowed-ips 2>/dev/null | awk '{print $2}' | cut -d/ -f1)"
  for ip in $(seq 2 254); do
    if ! printf '%s\n' "${used}" | grep -qx "${base}.${ip}"; then
      printf '%s.%s' "${base}" "${ip}"
      return 0
    fi
  done
  return 1
}
