#!/usr/bin/env bash
# wg-server.sh —— 在服务器上建立 WireGuard 管理内网，SSH 只经 wg0 可达。
#
#   sudo bash wg-server.sh                建 wg0 并放行 SSH（公网规则是否关闭另说）
#   sudo bash wg-server.sh --close-public 建好后关掉公网的 SSH 放行
#   sudo bash wg-server.sh --check        只报告状态
#   sudo bash wg-server.sh --uninstall    停止 wg0 并恢复公网 SSH 放行
#
# 幂等：重复执行只补齐缺失部分。公网 SSH 只在 --close-public 时关闭，
# 且关闭前要求 wg0 已带至少一个对端，否则拒绝执行。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/wg-lib.sh
. "${SELF_DIR}/wg-lib.sh"

CLOSE_PUBLIC=0
MODE=apply
while [[ $# -gt 0 ]]; do
  case "$1" in
    --close-public) CLOSE_PUBLIC=1 ;;
    --check | --status) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    -h | --help)
      cat <<'EOF'
用法：sudo bash wg-server.sh [选项]

  --close-public  关闭公网的 SSH 放行，SSH 之后只从 wg0 进
  --check         只报告状态，不改任何东西
  --uninstall     停止 wg0，恢复公网 SSH 放行
  -h, --help      显示帮助

环境变量：WG_PORT（默认 443/udp）、WG_ADDR（默认 10.66.0.1/24）、SSH_PORT（默认取 sshd 实际端口）
EOF
      exit 0
      ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

SSH_P="$(ssh_port)"

show() {
  printf 'wg0 状态   : %s\n' "$(wg_up && printf 'up' || printf 'down')"
  if wg_up; then
    printf '监听端口   : %s\n' "$(wg show "${WG_IF}" listen-port 2>/dev/null || printf '未知')"
    printf '服务端地址 : %s\n' "$(ip -4 -o addr show "${WG_IF}" 2>/dev/null | awk '{print $4}')"
    printf '对端数量   : %s\n' "$(wg show "${WG_IF}" peers 2>/dev/null | grep -c . || true)"
    wg show "${WG_IF}" latest-handshakes 2>/dev/null | while read -r pub ts; do
      [[ "${ts}" == "0" ]] && printf '  对端握手   : 无（%s…）\n' "${pub:0:8}" || printf '  对端握手   : %s（%s…）\n' "$(date -u -d "@${ts}" '+%F %T')" "${pub:0:8}"
    done
  fi
  printf 'sshd 端口  : %s\n' "${SSH_P}"
  if command -v ufw >/dev/null 2>&1; then
    printf 'ufw        : %s\n' "$(ufw status | head -1)"
    ufw status numbered | grep -E "${WG_PORT}/udp|${SSH_P}/tcp|on ${WG_IF}" || printf '  （没有相关规则）\n'
  fi
}

if [[ "${MODE}" == check ]]; then
  show
  exit 0
fi

need_root

if [[ "${MODE}" == uninstall ]]; then
  systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  if command -v ufw >/dev/null 2>&1; then
    ufw --force delete allow "${WG_PORT}/udp" >/dev/null 2>&1 || true
    ufw --force delete allow in on "${WG_IF}" to any port "${SSH_P}" proto tcp >/dev/null 2>&1 || true
    ufw allow "${SSH_P}/tcp" comment 'ssh' >/dev/null
  fi
  log "wg0 已停用，公网 ${SSH_P}/tcp 已恢复放行"
  exit 0
fi

log "1/5 安装 wireguard-tools"
need_cmd ip
if ! command -v wg >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wireguard-tools >/dev/null
fi
command -v wg >/dev/null 2>&1 || die "wg 装完仍找不到，检查 apt 输出"

log "2/5 生成或复用服务端密钥"
install -d -m 700 "${WG_DIR}"
if [[ ! -s "${WG_DIR}/server.key" ]]; then
  umask 077
  wg genkey >"${WG_DIR}/server.key"
fi
chmod 600 "${WG_DIR}/server.key"
SERVER_PRIV="$(cat "${WG_DIR}/server.key")"
[[ -n "${SERVER_PRIV}" ]] || die "服务端私钥为空"
SERVER_PUB="$(printf '%s' "${SERVER_PRIV}" | wg pubkey)"

log "3/5 写 ${WG_CONF}（监听 ${WG_PORT}/udp，地址 ${WG_ADDR}）"
install -d -m 700 "${WG_DIR}/peers" "${WG_DIR}/clients"
if [[ -f "${WG_CONF}" ]]; then
  cp -a "${WG_CONF}" "${WG_CONF}.bak"
  # 保留已有对端，只重写 [Interface] 段
  awk '/^\[Peer\]/{keep=1} keep' "${WG_CONF}" >"${WG_DIR}/peers.tmp"
else
  : >"${WG_DIR}/peers.tmp"
fi
{
  printf '[Interface]\n'
  printf 'Address = %s\n' "${WG_ADDR}"
  printf 'ListenPort = %s\n' "${WG_PORT}"
  printf 'PrivateKey = %s\n' "${SERVER_PRIV}"
  printf 'SaveConfig = false\n'
  if [[ -s "${WG_DIR}/peers.tmp" ]]; then
    printf '\n'
    cat "${WG_DIR}/peers.tmp"
  fi
} >"${WG_CONF}.new"
mv "${WG_CONF}.new" "${WG_CONF}"
rm -f "${WG_DIR}/peers.tmp"
chmod 600 "${WG_CONF}"
printf '%s\n' "${SERVER_PUB}" >"${WG_DIR}/server.pub"

# 写盘后先让 wg-quick 校验一次：配置不合法就不要重启，避免把隧道停掉
if ! wg-quick strip "${WG_IF}" >/dev/null 2>&1; then
  die "${WG_CONF} 不合法，wg-quick strip 校验失败，未重启 ${WG_IF}"
fi
chmod 644 "${WG_DIR}/server.pub"

log "4/5 启动 wg-quick@${WG_IF}"
systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
systemctl restart "wg-quick@${WG_IF}"
sleep 1
wg_up || {
  journalctl -u "wg-quick@${WG_IF}" -n 20 --no-pager >&2 || true
  die "wg0 未起来，见上方日志"
}

log "5/5 防火墙：放行 ${WG_PORT}/udp，SSH 只允许从 ${WG_IF} 进"
command -v ufw >/dev/null 2>&1 || die "本脚本按 ufw 写，当前没有 ufw"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${WG_PORT}/udp" comment 'wireguard' >/dev/null
ufw allow in on "${WG_IF}" to any port "${SSH_P}" proto tcp comment 'ssh via wg' >/dev/null

PEERS="$(wg show "${WG_IF}" peers 2>/dev/null | grep -c . || true)"
if [[ "${CLOSE_PUBLIC}" == 1 ]]; then
  [[ "${PEERS}" -gt 0 ]] || die "wg0 还没有任何对端，关闭公网 SSH 会把人挡在外面。先跑 wg-client.sh --add <名字>"
  if wg show "${WG_IF}" latest-handshakes 2>/dev/null | awk '{print $2}' | grep -qvx '0'; then
    log "至少一个对端完成过握手"
  else
    warn "还没有对端完成握手：先确认客户端能连上 10.66.0.1 再关闭公网 SSH"
  fi
  ufw --force delete allow "${SSH_P}/tcp" >/dev/null 2>&1 || true
  _left="$(ufw status | grep -E "^${SSH_P}/tcp[[:space:]]+(ALLOW|LIMIT)" || true)"
  [[ -z "${_left}" ]] || die "ufw 里仍有公网 SSH 规则：${_left}"
  log "公网 ${SSH_P}/tcp 已关闭，SSH 仅经 ${WG_IF} 可达"
else
  log "公网 ${SSH_P}/tcp 保持放行，确认客户端可用后再加 --close-public"
fi

show
