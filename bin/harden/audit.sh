#!/usr/bin/env bash
# bin/harden/audit.sh —— 从运维机独立验收 SSH 加固结果，不改动任何一端配置。
#
#   bash bin/harden/audit.sh --alias vps
#   bash bin/harden/audit.sh --host 203.0.113.10 --port 4061
#
# 检查项：本机密钥与配置、密钥登录可用、密码登录被拒、服务端 sshd 生效值、
# 端口速率限制与 fail2ban 状态。任一失败退出码 1。
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/ssh-lib.sh
. "${SELF_DIR}/../lib/ssh-lib.sh"

HOST=""
PORT=""
ALIAS="vps"
PROBE_USER="root"

if [[ $# -eq 0 ]]; then
  if ui_has_tty; then
    ui_ask "使用 ~/.ssh/config 的别名" "vps"
    ALIAS="${UI_ANSWER}"
  else
    ui_require_tty
  fi
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      shift
      HOST="${1:?--host 需要地址}"
      ;;
    --port)
      shift
      PORT="${1:?--port 需要端口}"
      ;;
    --alias)
      shift
      ALIAS="${1:?--alias 需要别名}"
      ;;
    --user)
      shift
      PROBE_USER="${1:?--user 需要用户名}"
      ;;
    -h | --help)
      cat <<'EOF'
用法：bash bin/harden/audit.sh [选项]

  --alias NAME   使用 ~/.ssh/config 里的别名，默认 vps
  --host ADDR    直接给地址，与 --alias 二选一
  --port N       端口，配合 --host 使用
  --user NAME    探测用用户，默认 root
  -h, --help     显示帮助
EOF
      exit 0
      ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  \033[32m✓\033[0m %s\n' "$*"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  \033[31m✗\033[0m %s\n' "$*"
}

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
if [[ -n "${HOST}" ]]; then
  TARGET="${PROBE_USER}@${HOST}"
  [[ -n "${PORT}" ]] && SSH_OPTS+=(-p "${PORT}")
else
  TARGET="${ALIAS}"
fi

printf '== 1. 本机准备 ==\n'
if [[ -f "${HOME}/.ssh/id_ed25519" ]]; then
  ok "本机存在 Ed25519 私钥：$(ssh-keygen -lf "${HOME}/.ssh/id_ed25519.pub" 2>/dev/null | awk '{print $1, $2}')"
else
  bad "本机没有 ${HOME}/.ssh/id_ed25519，先跑 bin/harden/client.sh"
fi
if [[ -n "${HOST}" ]]; then
  ok "直接指定目标：${TARGET}"
elif grep -q "^Host ${ALIAS}$" "${HOME}/.ssh/config" 2>/dev/null; then
  ok "${HOME}/.ssh/config 有 Host ${ALIAS}"
else
  bad "${HOME}/.ssh/config 里没有 Host ${ALIAS}"
fi

printf '== 2. 密钥登录 ==\n'
if ssh "${SSH_OPTS[@]}" "${TARGET}" true 2>/dev/null; then
  ok "公钥登录成功"
else
  bad "公钥登录失败（先修好这一条，后面的检查才有意义）"
fi

printf '== 3. 密码登录应被拒 ==\n'
PW_OUT="$(ssh -o BatchMode=no -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
  ${PORT:+-p "${PORT}"} "${TARGET}" true </dev/null 2>&1 || true)"
if printf '%s' "${PW_OUT}" | grep -q "Permission denied (publickey"; then
  ok "服务端只提供公钥方式，密码被拒"
elif printf '%s' "${PW_OUT}" | grep -qi "password"; then
  bad "服务端仍在提供密码认证：$(printf '%s' "${PW_OUT}" | tail -1)"
else
  warn "无法判断密码认证状态：$(printf '%s' "${PW_OUT}" | tail -1)"
fi

printf '== 4. 服务端 sshd 生效值 ==\n'
# ufw limit 对同一来源限制 6 次/30 秒，验收必须复用同一条连接，否则会限住自己
REMOTE="$(
  ssh "${SSH_OPTS[@]}" "${TARGET}" 'bash -s' <<'REMOTE_EOF' 2>/dev/null || true
sshd -T 2>/dev/null | sed 's/^/SSHD /'
ufw status numbered 2>/dev/null | grep -E "/tcp" | sed 's/^/UFW /'
fail2ban-client status sshd 2>/dev/null | sed 's/^/F2B /'
grep -cE '^(ssh-|ecdsa-)' "${HOME}/.ssh/authorized_keys" 2>/dev/null | sed 's/^/KEYS /'
REMOTE_EOF
)"
SSHD_OUT="$(printf '%s\n' "${REMOTE}" | sed -n 's/^SSHD //p')"
UFW_OUT="$(printf '%s\n' "${REMOTE}" | sed -n 's/^UFW //p')"
F2B_OUT="$(printf '%s\n' "${REMOTE}" | sed -n 's/^F2B //p')"
KEYS_OUT="$(printf '%s\n' "${REMOTE}" | sed -n 's/^KEYS //p')"

if [[ -z "${SSHD_OUT}" ]]; then
  bad "读不到服务端 sshd -T（需要 root 或免密 sudo）"
else
  get() { printf '%s\n' "${SSHD_OUT}" | awk -v k="$1" 'tolower($1) == k { print $2; exit }'; }
  check_val() { # $1=键 $2=期望描述 $3=匹配模式
    local v
    v="$(get "$1")"
    if [[ "${v}" =~ $3 ]]; then
      ok "$1 = ${v}"
    else
      bad "$1 = ${v:-未设置}，期望 $2"
    fi
  }
  check_val passwordauthentication "no" '^no$'
  check_val kbdinteractiveauthentication "no" '^no$'
  check_val permitrootlogin "prohibit-password 或 no" '^(prohibit-password|without-password|no)$'
  check_val pubkeyauthentication "yes" '^yes$'
  check_val maxauthtries "不超过 3" '^[123]$'
  printf '  · MaxStartups = %s，LoginGraceTime = %s，ClientAliveInterval = %s\n' \
    "$(get maxstartups)" "$(get logingracetime)" "$(get clientaliveinterval)"
fi

printf '== 5. 运行态防护 ==\n'
if printf '%s' "${UFW_OUT}" | grep -q "LIMIT"; then
  ok "存在 LIMIT 速率限制规则"
  # 只针对 SSH 端口的全局 ALLOW；限定网卡或来源的规则、其他端口的规则都不算绕过
  REMOTE_PORT="$(printf '%s
' "${SSHD_OUT}" | awk 'tolower($1) == "port" { print $2; exit }')"
  if printf '%s
' "${UFW_OUT}" | grep -vE " on " | grep -qE "] ${REMOTE_PORT}/tcp[[:space:]]+ALLOW"; then
    warn "端口 ${REMOTE_PORT} 还有全局 ALLOW 规则，速率限制会被绕过"
  else
    ok "端口 ${REMOTE_PORT} 没有全局 ALLOW 规则覆盖"
  fi
else
  bad "ufw 里看不到 LIMIT 规则"
fi
if printf '%s' "${F2B_OUT}" | grep -q "Status for the jail: sshd"; then
  ok "fail2ban sshd jail 已启用"
else
  bad "fail2ban 未启用 sshd jail"
fi
case "${KEYS_OUT}" in
  '' | 0) bad "服务端 authorized_keys 里没有可用公钥" ;;
  *) ok "服务端可用公钥数：${KEYS_OUT}" ;;
esac
printf '\n通过 %d 项，失败 %d 项\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]] || exit 1
