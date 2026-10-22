#!/usr/bin/env bash
# 90-uninstall.sh —— 拆掉 SPA，恢复公网 SSH 直连。交互式优先，关键选择不设默认值。
# 顺序：先放行公网 SSH 并回读确认，才停 fwknopd——反过来中间那段时间没有任何规则放行 SSH。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$SELF_DIR/lib.sh"

MODE=server
CHECK=0
PURGE=0
ASSUME_YES=0
KEYS="./spa-keys.env"
PW_ACTION=""      # yes | no           空 = 必须问，或由参数给
ROOT_LOGIN=""     # yes | no | prohibit-password

SSHD_MAIN="${SSHD_MAIN:-/etc/ssh/sshd_config}"
SSHD_DROPIN_DIR="${SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
FWK_DIR="${FWK_DIR:-/etc/fwknop}"
FWD_CONF="$FWK_DIR/fwknopd.conf"
FWD_ORIG="$FWK_DIR/fwknopd.conf.orig"
ACCESS_CONF="$FWK_DIR/access.conf"

usage() {
  cat <<'EOF'
用法：sudo bash 90-uninstall.sh [选项]       # 服务端
      bash 90-uninstall.sh --client [选项]  # 客户端

  --check                      只看现状，不改任何东西
  --client                     还原 ~/.fwknoprc 与 ~/.ssh/config 的托管块
  --password yes|no            退出后是否允许密码登录（交互式会问）
  --root-login yes|no|prohibit-password
                               root 的登录方式；--password yes 时必须一并给
  --purge                      连 access.conf 与密钥包一起删
  --keys FILE                  密钥包路径，默认 ./spa-keys.env
  -y, --yes                    跳过拆除确认（非交互运行必带）
  -h, --help                   显示帮助

非交互运行不接受默认值：--password 与 -y 必须显式给，缺了就退出。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client) MODE=client ;;
    --server) MODE=server ;;
    --check | --status) CHECK=1 ;;
    --purge) PURGE=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    --keys) shift; KEYS="${1:?--keys 需要参数}" ;;
    --keys=*) KEYS="${1#*=}" ;;
    --password) shift; PW_ACTION="${1:?--password 需要参数（yes|no）}" ;;
    --password=*) PW_ACTION="${1#*=}" ;;
    --root-login) shift; ROOT_LOGIN="${1:?--root-login 需要参数}" ;;
    --root-login=*) ROOT_LOGIN="${1#*=}" ;;
    -h | --help) usage; exit 0 ;;
    *) usage; die "未知参数：$1" ;;
  esac
  shift
done

case "$PW_ACTION" in "" | yes | no) ;; *) die "--password 只能是 yes / no" ;; esac
case "$ROOT_LOGIN" in "" | yes | no | prohibit-password) ;; *) die "--root-login 只能是 yes / no / prohibit-password" ;; esac

# 交互提问。答案放 ASK_REPLY，不用命令替换，免得 die 被吞进子 shell。
ASK_REPLY=""
ask() {
  local prompt="$1" def="${2:-n}" ans=""
  [[ -t 0 ]] || die "非交互运行：这一步必须用参数给定（见 --help）"
  printf '%s ' "$prompt" >&2
  read -r ans || die "读不到输入"
  ans="$(printf '%s' "${ans:-$def}" | tr '[:upper:]' '[:lower:]')"
  case "$ans" in
    y | yes) ASK_REPLY=y ;;
    n | no) ASK_REPLY=n ;;
    *) die "只接受 y 或 n" ;;
  esac
}

sshd_get() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k{print $2; exit}'; }

# ---------------------------------------------------------------- 客户端

run_client() {
  [[ -f "$SELF_DIR/20-client.sh" ]] || die "找不到同目录下的 20-client.sh"
  if [[ "$CHECK" == 1 ]]; then
    bash "$SELF_DIR/20-client.sh" --status || true
    return 0
  fi
  bash "$SELF_DIR/20-client.sh" --uninstall
  log "客户端已还原：~/.ssh/config 托管块与 ~/.fwknoprc 已清，ssh 直连"
  if [[ "$PURGE" == 0 ]] && [[ -e "$KEYS" ]]; then
    ask "删除本地密钥包 ${KEYS}？[y/N]" n
    [[ "$ASK_REPLY" == y ]] && PURGE=1 || true
  fi
  if [[ "$PURGE" == 1 ]] && [[ -e "$KEYS" ]]; then
    rm -f "$KEYS"
    log "已删 ${KEYS}"
  fi
  warn "服务端的 access.conf 与密钥包不在这台机器上，要删得去服务器跑 --purge"
}

[[ "$MODE" == client ]] && { run_client; exit 0; }

# ---------------------------------------------------------------- 服务端

# 密钥包里的 SPA_PORT，读不到就用默认 62201
SPA_PORT="$(grep -E '^SPA_PORT=' "$KEYS" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "\"' " || true)"
case "$SPA_PORT" in '' | *[!0-9]*) SPA_PORT=62201 ;; esac
PORTS=""

show_status() {
  printf 'fwknopd    : %s\n' "$(command -v fwknopd >/dev/null 2>&1 && (systemctl is-active fwknop-server 2>/dev/null || echo 未知) || echo 未安装)"
  printf 'INPUT 跳转 : %s\n' "$(iptables -S INPUT 2>/dev/null | grep -q FWKNOP_INPUT && echo '在，SPA 仍在接管' || echo '不在，SPA 未接管')"
  printf '临时放行   : %s 条\n' "$(iptables -S FWKNOP_INPUT 2>/dev/null | grep -c '^-A' || true)"
  printf 'SSH 端口   : %s\n' "$(ssh_resolve_ports 2>/dev/null || echo '探测不到，用 SSH_PORT= 指定')"
  if command -v sshd >/dev/null 2>&1 && sshd -T >/dev/null 2>&1; then
    printf '登录策略   : %s\n' "$(sshd -T 2>/dev/null | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) ' | paste -sd' ' -)"
  fi
  if command -v ufw >/dev/null 2>&1; then
    printf 'ufw        : %s\n' "$(ufw status | head -1)"
    ufw status | grep -E "($(printf '%s' "${PORTS:-22}" | tr ' ' '|'))/tcp|${SPA_PORT}/udp" | sed 's/^/             /' || true
  fi
}

if [[ "$CHECK" == 1 ]]; then
  [[ "$(id -u)" == 0 ]] || warn "非 root：iptables / ufw 的信息可能读不到（加 sudo 更完整）"
  show_status
  exit 0
fi

need_root
PORTS="$(ssh_resolve_ports)"

# ---------------------------------------------------------------- 登录方式（必问）

PW_NOW="$(sshd_get passwordauthentication || true)"
KI_NOW="$(sshd_get kbdinteractiveauthentication || true)"
RL_NOW="$(sshd_get permitrootlogin || true)"

if [[ -z "$PW_ACTION" ]]; then
  printf '\n当前：PasswordAuthentication=%s  KbdInteractiveAuthentication=%s  PermitRootLogin=%s\n' \
    "${PW_NOW:-?}" "${KI_NOW:-?}" "${RL_NOW:-?}"
  [[ -t 0 ]] || die "非交互运行必须显式给 --password yes|no"
  ask "允许密码登录？[y/N]" n
  [[ "$ASK_REPLY" == y ]] && PW_ACTION=yes || PW_ACTION=no
fi

if [[ "$PW_ACTION" == yes ]]; then
  case "$RL_NOW" in
    prohibit-password | without-password)
      if [[ -z "$ROOT_LOGIN" ]]; then
        if [[ -t 0 ]]; then
          warn "PermitRootLogin=${RL_NOW}，仅开 PasswordAuthentication 时 root 仍无法用密码登录"
          ask "root 也允许密码登录？[y/N]" n
          [[ "$ASK_REPLY" == y ]] && ROOT_LOGIN=yes
        else
          die "--password yes 时需一并给 --root-login：当前 PermitRootLogin=${RL_NOW}
       root 用密码登录：--root-login yes；仅普通用户：--root-login prohibit-password"
        fi
      fi
      ;;
  esac
fi

# 拆之前先确认还有别的进门方式：没有公钥、又要关密码登录 = 拆完只剩云控制台
if [[ "$PW_ACTION" == no ]]; then
  keyed=0
  for u in root "${SUDO_USER:-}"; do
    [[ -n "$u" ]] || continue
    h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)"
    if [[ -n "$h" ]] && ls "$h"/.ssh/authorized_keys* >/dev/null 2>&1; then keyed=$((keyed + 1)); fi
  done
  [[ "$keyed" -gt 0 ]] || warn "未在 root 与当前用户的 HOME 下找到 authorized_keys：拆除后仅公钥可登录"
fi

if [[ "$PURGE" == 0 ]] && { [[ -e "$ACCESS_CONF" ]] || [[ -e "$KEYS" ]]; }; then
  if [[ -t 0 ]]; then
    ask "同时删除 access.conf 与密钥包？[y/N]" n
    [[ "$ASK_REPLY" == y ]] && PURGE=1 || true
  fi
fi

if [[ "$ASSUME_YES" == 0 ]]; then
  [[ -t 0 ]] || die "非交互运行要加 -y 确认拆除"
  ask "确认拆除 SPA？公网 SSH 会重新对全网开放 [y/N]" n
  [[ "$ASK_REPLY" == y ]] || { log "已取消，未做改动"; exit 0; }
fi

# 1) 先开公网 SSH —— 不成功就绝不继续拆
log "1/6 放行公网 SSH：${PORTS}/tcp"
if command -v ufw >/dev/null 2>&1; then
  for p in $PORTS; do ufw allow "$p/tcp" comment 'ssh' >/dev/null; done
  missing=""
  for p in $PORTS; do
    ufw status | grep -qE "^${p}/tcp[[:space:]]+(ALLOW|LIMIT)" || missing="$missing $p"
  done
  [[ -z "$missing" ]] || die "ufw 没放行成：${missing}。SPA 还完整，先去排查"
  log "    回读确认：${PORTS}/tcp 已放行"
else
  warn "    未安装 ufw，跳过放行"
fi

# 2) 停 fwknopd
log "2/6 停用 fwknop-server"
systemctl disable --now fwknop-server >/dev/null 2>&1 || warn "    停用失败，继续清 iptables"

# 3) 清 iptables
log "3/6 删除 INPUT 跳转与 FWKNOP_INPUT 链"
iptables -D INPUT -j FWKNOP_INPUT 2>/dev/null || true
iptables -F FWKNOP_INPUT 2>/dev/null || true
iptables -X FWKNOP_INPUT 2>/dev/null || true
iptables -S INPUT 2>/dev/null | grep -q FWKNOP_INPUT && warn "    INPUT 里还有 FWKNOP_INPUT 跳转，手工删"

# 4) 关 SPA 端口
log "4/6 关闭 SPA 端口 ${SPA_PORT}/udp"
if command -v ufw >/dev/null 2>&1; then
  ufw --force delete allow "${SPA_PORT}/udp" >/dev/null 2>&1 || true
  ufw status | grep -q "${SPA_PORT}/udp" && warn "    ufw 里还有 ${SPA_PORT}/udp，手工删"
fi

# 5) 还原 fwknopd.conf
log "5/6 还原 fwknopd.conf"
if [[ -f "$FWD_ORIG" ]]; then
  mv "$FWD_ORIG" "$FWD_CONF"
else
  warn "    未找到 ${FWD_ORIG}，fwknopd.conf 保持现状"
fi

# 6) 登录策略。sshd 对同一关键字只取第一个出现的值，Include 按文件名排序就地展开，
#    所以改的必须是「排序最靠前、且写了该关键字」的那一份。
sshd_uses_dropin() { grep -qiE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_MAIN" 2>/dev/null; }

first_file_with_key() {
  local key="$1" f
  if sshd_uses_dropin; then
    for f in "$SSHD_DROPIN_DIR"/*.conf; do
      [[ -f "$f" ]] || continue
      grep -qiE "^[[:space:]]*${key}[[:space:]]" "$f" && { printf '%s\n' "$f"; return 0; }
    done
  fi
  grep -qiE "^[[:space:]]*${key}[[:space:]]" "$SSHD_MAIN" && { printf '%s\n' "$SSHD_MAIN"; return 0; }
  return 1
}

set_sshd_key() {
  local key="$1" val="$2" f=""
  f="$(first_file_with_key "$key" || true)"
  if [[ -z "$f" ]]; then
    if sshd_uses_dropin; then
      mkdir -p "$SSHD_DROPIN_DIR"
      f="$SSHD_DROPIN_DIR/99-ssh-spa.conf"
      [[ -f "$f" ]] || : >"$f"
    else
      f="$SSHD_MAIN"
    fi
  fi
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    { if (!done && tolower($1) == tolower(k)) { print k " " v; done = 1; next } print }
    END { if (!done) print k " " v }
  ' "$f" >"$f.spa.tmp" && mv "$f.spa.tmp" "$f"
  chmod 644 "$f" 2>/dev/null || true
  log "    ${f} → ${key} ${val}"
}

log "6/6 登录策略：password=${PW_ACTION}${ROOT_LOGIN:+ root-login=${ROOT_LOGIN}}"
if command -v sshd >/dev/null 2>&1 && [[ -r "$SSHD_MAIN" ]]; then
  set_sshd_key PasswordAuthentication "$PW_ACTION"
  [[ "$PW_ACTION" == no ]] && set_sshd_key KbdInteractiveAuthentication no
  [[ -n "$ROOT_LOGIN" ]] && set_sshd_key PermitRootLogin "$ROOT_LOGIN"
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null ||
      systemctl restart sshd 2>/dev/null || warn "    reload/restart ssh 失败，新策略可能没生效"
    got_pw="$(sshd_get passwordauthentication || true)"
    [[ "$got_pw" == "$PW_ACTION" ]] || {
      warn "    passwordauthentication 仍为 ${got_pw:-?}，以下位置设置了该关键字："
      grep -rniE --exclude='*.orig' '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication)' \
        "$SSHD_MAIN" "$SSHD_DROPIN_DIR" 2>/dev/null | while IFS= read -r l; do warn "      $l"; done
    }
    [[ -z "$ROOT_LOGIN" ]] || [[ "$(sshd_get permitrootlogin || true)" == "$ROOT_LOGIN" ]] ||
      warn "    permitrootlogin 仍是 $(sshd_get permitrootlogin || true)"
  else
    warn "    sshd -t 未通过，先修 ${SSHD_MAIN} 与 ${SSHD_DROPIN_DIR}，不要 restart"
  fi
else
  warn "    找不到 sshd 或读不到 ${SSHD_MAIN}，登录策略未动"
fi

show_status
printf '\n'
log "SPA 已拆除，公网 SSH 直连 ${PORTS}/tcp"
[[ "$PW_ACTION" = yes ]] && warn "密码登录已开启，确认 fail2ban 在运行：fail2ban-client status sshd"

if [[ "$PURGE" == 1 ]]; then
  rm -f "$ACCESS_CONF" "$KEYS"
  log "已删除 ${ACCESS_CONF} 与 ${KEYS}"
else
  printf '保留 %s、%s，加 --purge 可删除\n' "$ACCESS_CONF" "$KEYS"
fi
printf '客户端各自还原：bash 90-uninstall.sh --client\n'
