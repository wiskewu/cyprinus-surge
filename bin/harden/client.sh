#!/usr/bin/env bash
# bin/harden/client.sh —— 在运维机上准备免密登录：生成 Ed25519 密钥、装公钥、写 ~/.ssh/config。
#
#   bash bin/harden/client.sh --host 203.0.113.10 --port 4061 --install-server
#   bash bin/harden/client.sh --host 203.0.113.10 --check
#
# 幂等：已有 ed25519 密钥就复用，公钥已存在不重复追加，config 里已有同名 Host 不重复写。
# 装公钥需要一次现有登录方式（密码或已有密钥），不会覆盖 authorized_keys 里其他行。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/ssh-lib.sh
. "${SELF_DIR}/../lib/ssh-lib.sh"

HOST=""
PORT=""
USER_NAME="root"
ALIAS="vps"
INSTALL=0
MODE=apply

if [[ $# -eq 0 ]]; then
  if ui_has_tty; then
    ui_ask "服务器地址"
    INTERACTIVE_HOST="${UI_ANSWER}"
    ui_ask "端口" "22"
    INTERACTIVE_PORT="${UI_ANSWER}"
    ui_ask "登录用户" "root"
    INTERACTIVE_USER="${UI_ANSWER}"
    ui_ask "别名" "vps"
    INTERACTIVE_ALIAS="${UI_ANSWER}"
    set -- --host "${INTERACTIVE_HOST}" --port "${INTERACTIVE_PORT}" --user "${INTERACTIVE_USER}" --alias "${INTERACTIVE_ALIAS}"
    ui_confirm "顺手把公钥装到服务器" y && set -- "$@" --install-server
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
    --user)
      shift
      USER_NAME="${1:?--user 需要用户名}"
      ;;
    --alias)
      shift
      ALIAS="${1:?--alias 需要别名}"
      ;;
    --install-server) INSTALL=1 ;;
    --check) MODE=check ;;
    -h | --help)
      cat <<'EOF'
用法：bash bin/harden/client.sh --host <地址> [选项]

  --host ADDR       服务器地址，必填
  --port N          端口，默认取 ~/.ssh/config 里该别名已有的值，否则 22
  --user NAME       登录用户，默认 root
  --alias NAME      写进 ~/.ssh/config 的别名，默认 vps
  --install-server  把本机公钥追加到服务器的 authorized_keys
  --check           只报告本机密钥与配置状态
  -h, --help        显示帮助
EOF
      exit 0
      ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

KEY="${HOME}/.ssh/id_ed25519"
CFG="${HOME}/.ssh/config"

if [[ "${MODE}" == check ]]; then
  printf '密钥           : %s\n' "$([[ -f "${KEY}" ]] && ssh-keygen -lf "${KEY}.pub" 2>/dev/null || printf '不存在')"
  printf 'config 别名    : %s\n' "$(grep -q "^Host ${ALIAS}$" "${CFG}" 2>/dev/null && printf '存在' || printf '不存在')"
  exit 0
fi

[[ -n "${HOST}" ]] || die "缺少 --host"
install -d -m 700 "${HOME}/.ssh"

if [[ ! -f "${KEY}" ]]; then
  log "生成 Ed25519 密钥 ${KEY}"
  ssh-keygen -t ed25519 -N '' -C "${USER_NAME}@$(hostname)" -f "${KEY}" >/dev/null
else
  log "复用已有密钥：$(ssh-keygen -lf "${KEY}.pub" 2>/dev/null || printf '%s' "${KEY}")"
fi
chmod 600 "${KEY}"
[[ -f "${KEY}.pub" ]] || die "缺少公钥 ${KEY}.pub"

if [[ "${INSTALL}" == 1 ]]; then
  PUB="$(cat "${KEY}.pub")"
  TARGET_PORT="${PORT:-22}"
  log "把公钥装到 ${USER_NAME}@${HOST}:${TARGET_PORT}"
  # 先看是否已在服务器上，避免重复追加
  if ssh -p "${TARGET_PORT}" -o StrictHostKeyChecking=accept-new "${USER_NAME}@${HOST}" \
    "grep -qF '${PUB}' ~/.ssh/authorized_keys 2>/dev/null"; then
    log "    公钥已存在，跳过"
  else
    ssh -p "${TARGET_PORT}" -o StrictHostKeyChecking=accept-new "${USER_NAME}@${HOST}" \
      "umask 077; mkdir -p ~/.ssh; printf '%s\n' '${PUB}' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
    log "    已追加"
  fi
fi

if [[ -z "${PORT}" ]]; then
  PORT="$(awk -v a="${ALIAS}" '
    $1 == "Host" { inblock = ($2 == a) ; next }
    inblock && $1 == "Port" { print $2; exit }
  ' "${CFG}" 2>/dev/null || true)"
  PORT="${PORT:-22}"
fi

touch "${CFG}"
chmod 600 "${CFG}"
if grep -q "^Host ${ALIAS}$" "${CFG}"; then
  log "${CFG} 已有 Host ${ALIAS}，保持原样"
else
  {
    printf '\nHost %s\n' "${ALIAS}"
    printf '  HostName %s\n' "${HOST}"
    printf '  Port %s\n' "${PORT}"
    printf '  User %s\n' "${USER_NAME}"
    printf '  IdentityFile %s\n' "${KEY}"
    printf '  IdentitiesOnly yes\n'
  } >>"${CFG}"
  log "已写入 Host ${ALIAS} → ${USER_NAME}@${HOST}:${PORT}"
fi

log "验证免密登录"
if ssh -o BatchMode=yes -o ConnectTimeout=10 "${ALIAS}" true 2>/dev/null; then
  log "    成功：ssh ${ALIAS}"
else
  warn "    失败：检查服务器是否已装公钥、端口是否正确"
  exit 1
fi
