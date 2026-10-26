#!/usr/bin/env bash
# ssh-server.sh —— 服务端 SSH 加固：仅公钥登录、速率限制、fail2ban。
#
#   sudo bash ssh-server.sh                 应用加固，幂等
#   sudo bash ssh-server.sh --check         只看现状，不改动
#   sudo bash ssh-server.sh --uninstall     还原到加固前（恢复密码登录）
#
# 三条硬规则：
#   1. 关密码登录前必须存在可用公钥，且当前会话经公钥认证，否则拒绝执行；
#   2. 只 reload，不 restart；
#   3. 写盘后先 sshd -t，失败即回滚，不 reload。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/ssh-lib.sh
. "${SELF_DIR}/ssh-lib.sh"

MODE=apply
FORCE=0
WHITELIST="${WHITELIST:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) MODE=apply ;;
    --check | --status) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    --force) FORCE=1 ;;
    --whitelist) shift; WHITELIST="${1:?--whitelist 需要地址或网段}" ;;
    -h | --help)
      cat <<'EOF'
用法：sudo bash ssh-server.sh [选项]

  --check            只报告现状，不改动任何文件
  --apply            应用加固（默认）
  --uninstall        还原 sshd 与防火墙到加固前，恢复密码登录
  --whitelist IP     写入 fail2ban 的 ignoreip，可重复用逗号分隔
  --force            跳过「当前会话必须经公钥认证」的检查
  -h, --help         显示帮助

环境变量：SSH_PORT（默认取 sshd 实际端口）
EOF
      exit 0
      ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

SSH_P="$(ssh_port)"

check() {
  printf 'sshd 端口          : %s\n' "${SSH_P}"
  printf '密码登录           : %s\n' "$(sshd_get passwordauthentication || printf '未知')"
  printf 'root 登录          : %s\n' "$(sshd_get permitrootlogin || printf '未知')"
  printf '键盘交互           : %s\n' "$(sshd_get kbdinteractiveauthentication || printf '未知')"
  printf 'MaxAuthTries       : %s\n' "$(sshd_get maxauthtries || printf '未知')"
  printf 'MaxStartups        : %s\n' "$(sshd_get maxstartups || printf '未知')"
  printf 'LoginGraceTime     : %s\n' "$(sshd_get logingracetime || printf '未知')"
  printf '可用公钥数         : %s\n' "$(count_authorized_keys)"
  printf '本次会话公钥登录   : %s\n' "$(session_is_pubkey && printf '是' || printf '否/无法判定')"
  printf '加固片段           : %s\n' "$([[ -f "${DROPIN}" ]] && printf '存在' || printf '不存在')"
  if command -v ufw >/dev/null 2>&1; then
    printf 'ufw 应用层         : %s\n' "$(ufw status | head -1)"
    ufw status numbered | grep -E "^\[[ 0-9]+\] ${SSH_P}/tcp" || printf '  （没有 %s/tcp 规则）\n' "${SSH_P}"
  fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    printf 'fail2ban sshd      : %s\n' "$(fail2ban-client status sshd 2>/dev/null | awk -F'\t' '/Currently banned/{print $2}' | paste -sd' ' - || printf '未启用')"
  fi
}

if [[ "${MODE}" == check ]]; then
  check
  exit 0
fi

need_root

if [[ "${MODE}" == uninstall ]]; then
  if [[ -f "${DROPIN}" ]]; then
    rm -f "${DROPIN}"
    log "已删除 ${DROPIN}"
  fi
  # 恢复被就地改写的、排序更靠前的文件
  if [[ -d "${BACKUP_ROOT}/latest" ]]; then
    for f in "${BACKUP_ROOT}/latest"/*.conf; do
      [[ -f "${f}" ]] || continue
      base="$(basename "${f}")"
      cp -a "${f}" "${SSHD_DROPIN_DIR}/${base}"
      log "已还原 ${SSHD_DROPIN_DIR}/${base}"
    done
  fi
  set_sshd_key PasswordAuthentication yes || true
  set_sshd_key PermitRootLogin yes || true
  sshd -t || die "还原后 sshd -t 不通过，未 reload"
  systemctl reload ssh
  if command -v ufw >/dev/null 2>&1; then
    ufw --force delete limit "${SSH_P}/tcp" >/dev/null 2>&1 || true
    ufw allow "${SSH_P}/tcp" >/dev/null
  fi
  log "已恢复密码登录与普通放行，请立即确认能登录后再关闭当前会话"
  exit 0
fi

# ---------------------------------------------------------------- 前置检查
KEYS="$(count_authorized_keys)"
[[ "${KEYS}" -ge 1 ]] || die "找不到任何 authorized_keys，先装公钥：ssh-copy-id 或手工追加"
log "检测到 ${KEYS} 把可用公钥"

if session_is_pubkey; then
  log "当前会话经公钥认证"
elif [[ "${FORCE}" == 1 ]]; then
  warn "跳过会话认证检查（--force），关闭密码登录后请立刻验证新连接"
else
  die "无法确认当前会话是公钥登录。先用密钥登录一次再执行，或加 --force"
fi

# ---------------------------------------------------------------- 备份
TS="$(date +%Y%m%d-%H%M%S)"
BK="${BACKUP_ROOT}/${TS}"
install -d -m 700 "${BACKUP_ROOT}" "${BK}"
cp -a "${SSHD_MAIN}" "${BK}/sshd_config"
if [[ -d "${SSHD_DROPIN_DIR}" ]]; then
  install -d -m 700 "${BK}/dropin"
  cp -a "${SSHD_DROPIN_DIR}/." "${BK}/dropin/" 2>/dev/null || true
fi
if command -v ufw >/dev/null 2>&1; then
  ufw status numbered >"${BK}/ufw-status.txt" 2>&1 || true
fi
rm -rf "${BACKUP_ROOT}/latest"
cp -a "${BK}" "${BACKUP_ROOT}/latest"
log "已备份到 ${BK}"

# ---------------------------------------------------------------- 写 sshd 片段
install -d -m 755 "${SSHD_DROPIN_DIR}"
cat >"${DROPIN}" <<'EOF'
# 由 ssh-server.sh 生成：仅公钥登录。改这一份即可，不要手改 sshd_config 里的同名项。
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 20
MaxStartups 5:30:10
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF
chmod 644 "${DROPIN}"

# 排序更靠前的文件若写了同一关键字会赢，就地改掉
set_sshd_key PasswordAuthentication no
set_sshd_key PermitRootLogin prohibit-password
set_sshd_key KbdInteractiveAuthentication no

if ! sshd -t 2>/tmp/ssh-hardening.err; then
  cat /tmp/ssh-hardening.err >&2
  rm -f "${DROPIN}"
  die "sshd -t 不通过，已删除 ${DROPIN} 且未 reload，当前配置未变"
fi
rm -f /tmp/ssh-hardening.err
log "sshd -t 通过"

systemctl reload ssh
sleep 1

FAIL=""
[[ "$(sshd_get passwordauthentication)" == "no" ]] || FAIL="${FAIL} passwordauthentication"
KBD="$(sshd_get kbdinteractiveauthentication)"
[[ "${KBD}" == "no" ]] || FAIL="${FAIL} kbdinteractiveauthentication"
ROOTLOGIN="$(sshd_get permitrootlogin)"
case "${ROOTLOGIN}" in prohibit-password | without-password | no) ;; *) FAIL="${FAIL} permitrootlogin" ;; esac
if [[ -n "${FAIL}" ]]; then
  grep -rniE --exclude='*.orig' '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|PermitRootLogin)' \
    "${SSHD_MAIN}" "${SSHD_DROPIN_DIR}" 2>/dev/null | while IFS= read -r l; do warn "  ${l}"; done
  die "回读未生效：${FAIL}。上面是设置这些关键字的文件，改掉再重跑"
fi
log "回读确认：密码登录已关闭，root 仅密钥"

# ---------------------------------------------------------------- 防火墙
if command -v ufw >/dev/null 2>&1; then
  ufw limit "${SSH_P}/tcp" >/dev/null
  # 同一端口若还有 allow 规则，limit 形同虚设
  if ufw status | grep -qE "^${SSH_P}/tcp[[:space:]]+ALLOW"; then
    ufw --force delete allow "${SSH_P}/tcp" >/dev/null 2>&1 || true
  fi
  if ufw status | grep -qE "^${SSH_P}/tcp[[:space:]]+LIMIT"; then
    log "ufw：${SSH_P}/tcp 已改为 LIMIT"
  else
    die "ufw 里没有 ${SSH_P}/tcp 的 LIMIT 规则，端口可能不可达"
  fi
else
  warn "没有 ufw，跳过速率限制"
fi

# ---------------------------------------------------------------- fail2ban
if command -v fail2ban-client >/dev/null 2>&1; then
  IGNORE="127.0.0.1/8 ::1"
  [[ -n "${WHITELIST}" ]] && IGNORE="${IGNORE} ${WHITELIST//,/ }"
  cat >"${F2B_JAIL}" <<EOF
# 由 ssh-server.sh 生成
[DEFAULT]
ignoreip = ${IGNORE}
bantime = 1h
findtime = 10m
maxretry = 4

[sshd]
enabled = true
EOF
  fail2ban-client reload >/dev/null 2>&1 || systemctl restart fail2ban
  sleep 1
  systemctl is-active --quiet fail2ban || warn "fail2ban 未运行，封禁不会生效"
  if fail2ban-client status sshd >/dev/null 2>&1; then
    log "fail2ban：sshd jail 已启用"
  else
    warn "fail2ban 里没有 sshd jail"
  fi
else
  warn "没有 fail2ban，跳过"
fi

printf '\n'
check
cat <<EOF

加固完成。现在用另一个终端验证（不要关闭当前会话）：
  ssh -o BatchMode=yes -p ${SSH_P} root@<本机地址> true
确认可用后，本次改动才算生效；失败时执行 sudo bash ssh-server.sh --uninstall
EOF
