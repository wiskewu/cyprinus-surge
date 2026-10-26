#!/usr/bin/env bash
# 通用 SSH 加固脚本的共用函数。被 ssh-server.sh / ssh-client.sh / ssh-audit.sh
# source，不单独运行，也不改动调用方的 shell 选项。
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

DROPIN="${DROPIN:-/etc/ssh/sshd_config.d/99-ssh-hardening.conf}"
SSHD_MAIN="${SSHD_MAIN:-/etc/ssh/sshd_config}"
SSHD_DROPIN_DIR="${SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/ssh-hardening}"
F2B_JAIL="${F2B_JAIL:-/etc/fail2ban/jail.d/sshd-local.conf}"

# sshd 实际端口，不假设 22
ssh_port() {
  local p=""
  if command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" { print $2; exit }')"
  fi
  [[ -n "${p}" ]] || p="${SSH_PORT:-22}"
  printf '%s' "${p}"
}

sshd_get() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1) == k { print $2; exit }'; }

# 当前会话是否用公钥登录：靠 journal 里与本次连接源端口匹配的 Accepted publickey 记录
session_is_pubkey() {
  local cip cport
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  # SSH_CONNECTION 的字段顺序是「客户端 IP 客户端端口 服务端 IP 服务端端口」
  read -r cip cport _ _ <<<"${SSH_CONNECTION}"
  journalctl -u ssh --since "-30 min" --no-pager 2>/dev/null |
    grep -q "Accepted publickey for .* from ${cip} port ${cport}"
}

# 统计可用于登录的公钥数（root 与 sudo 用户的 authorized_keys）
count_authorized_keys() {
  local n=0 u home
  for u in root "${SUDO_USER:-}"; do
    [[ -n "${u}" ]] || continue
    home="$(getent passwd "${u}" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "${home}" ]] || continue
    if [[ -s "${home}/.ssh/authorized_keys" ]]; then
      n=$((n + $(grep -cE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" || true)))
    fi
  done
  printf '%s' "${n}"
}

# sshd 对同一关键字取第一个出现的值，Include 按文件名排序就地展开
sshd_uses_dropin() { grep -qiE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "${SSHD_MAIN}" 2>/dev/null; }

first_file_with_key() {
  local key="$1" f
  if sshd_uses_dropin; then
    for f in "${SSHD_DROPIN_DIR}"/*.conf; do
      [[ -f "${f}" ]] || continue
      [[ "${f}" == "${DROPIN}" ]] && continue
      grep -qiE "^[[:space:]]*${key}[[:space:]]" "${f}" && {
        printf '%s\n' "${f}"
        return 0
      }
    done
  fi
  grep -qiE "^[[:space:]]*${key}[[:space:]]" "${SSHD_MAIN}" && {
    printf '%s\n' "${SSHD_MAIN}"
    return 0
  }
  return 1
}

# 就地改写「第一个出现」的那一行，避免被排序更靠前的文件压过
set_sshd_key() {
  local key="$1" val="$2" f=""
  f="$(first_file_with_key "${key}" || true)"
  [[ -n "${f}" ]] || return 0
  awk -v k="${key}" -v v="${val}" '
    BEGIN { done = 0 }
    { if (!done && tolower($1) == tolower(k)) { print k " " v; done = 1; next } print }
  ' "${f}" >"${f}.tmp" && mv "${f}.tmp" "${f}"
  chmod 644 "${f}" 2>/dev/null || true
  log "    ${f} → ${key} ${val}"
}
