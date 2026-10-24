#!/usr/bin/env bash
# 09-harden.sh —— sing-box 降权与 systemd 沙箱。
#   装完 sing-box（10-install-singbox.sh 或 deploy.sh）之后跑一次；随时可用 --check 复查、
#   --revert 退回原来的单元文件。改完会重启服务，配置校验失败就自动回滚。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SELF_DIR}/lib.sh"

UNIT="/etc/systemd/system/sing-box.service"
UNIT_ORIG="${UNIT}.orig"
SB_USER="${SB_USER:-sing-box}"
MODE=apply

usage() {
  cat <<'EOF'
用法：sudo bash 09-harden.sh [选项]

  （不带选项）    降权 + 沙箱：建 system 用户、收权限、重写 unit、重启并自检
  --check         只报告当前状态，不改任何东西
  --revert        用备份的 .orig 覆盖回去并重启
  -h, --help      显示帮助

改动前会把原 unit 备份到 /etc/systemd/system/sing-box.service.orig，
写入后重启；服务没起来或端口没监听就自动回滚。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check ;;
    --revert) MODE=revert ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "未知参数：$1"
      ;;
  esac
  shift
done

# 端口从 deploy.env 取；取不到就不做端口自检，只验服务状态
# deploy.env 可有可无：有就读端口与开关。注意 die 是 exit，不能靠 || true 兜住
[[ -f "${ENVFILE}" ]] && load_env "${ENVFILE}"
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-8443}"
ENABLE_HY2="${ENABLE_HY2:-0}"

unit_has() { grep -qE "^$1=" "${UNIT}" 2>/dev/null; }

running_user() {
  local pid
  pid="$(pgrep -x sing-box | head -n1 || true)"
  [[ -n "${pid}" ]] || {
    printf '未运行'
    return 0
  }
  ps -o user= -p "${pid}" | tr -d ' '
}

report() {
  printf '%s\t%s\n' '单元文件' "${UNIT}"
  printf '%s\t%s\n' '服务状态' "$(systemctl is-active sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' '运行用户' "$(running_user)"
  printf '%s\t%s\n' 'NoNewPrivileges' "$(unit_has NoNewPrivileges && printf 'yes' || printf '未设置')"
  printf '%s\t%s\n' 'ProtectSystem' "$(unit_has ProtectSystem && grep -oE '^ProtectSystem=.*' "${UNIT}" | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' 'CapabilityBoundingSet' "$(unit_has CapabilityBoundingSet && grep -oE '^CapabilityBoundingSet=.*' "${UNIT}" | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' '备份' "$([[ -f "${UNIT_ORIG}" ]] && printf '%s' "${UNIT_ORIG}" || printf '无')"
}

port_listening() { # $1=tcp|udp $2=端口
  if [[ "$1" == tcp ]]; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  else
    ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  fi
}

verify_running() {
  local _try
  for _try in 1 2 3 4 5; do
    systemctl is-active --quiet sing-box && break
    sleep 1
  done
  systemctl is-active --quiet sing-box || return 1
  port_listening tcp "${VLESS_PORT}" || return 1
  if [[ "${ENABLE_HY2}" == "1" ]]; then
    port_listening udp "${HY2_PORT}" || return 1
  fi
  return 0
}

rollback() {
  warn "回滚到 ${UNIT_ORIG}"
  cp -a "${UNIT_ORIG}" "${UNIT}"
  systemctl daemon-reload
  systemctl restart sing-box || true
  sleep 1
  if systemctl is-active --quiet sing-box; then
    log "已恢复原单元，服务运行中"
  else
    warn "服务仍未起来，看 journalctl -u sing-box -n 50"
  fi
}

write_unit() {
  cat >"${UNIT}" <<EOF
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

# ---- 能力：只保留监听低端口、操作 nftables/路由、创建 TUN 所需的三项 ----
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

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
UMask=0077

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
  chmod 644 "${UNIT}"
}

case "${MODE}" in
  check)
    need_root
    report
    exit 0
    ;;
  revert)
    need_root
    [[ -f "${UNIT_ORIG}" ]] || die "没有备份 ${UNIT_ORIG}，无法回滚"
    rollback
    report
    exit 0
    ;;
esac

# ---------------------------------------------------------------- 应用
need_root
[[ -x "${SB_BIN}" ]] || die "找不到 ${SB_BIN}，先跑 10-install-singbox.sh"
[[ -s "${DEPLOY_DIR}/config.json" ]] || die "缺少 ${DEPLOY_DIR}/config.json，先跑 30-render-server.sh"
command -v systemctl >/dev/null 2>&1 || die "本脚本按 systemd 写"

log "1/4 准备 system 用户 ${SB_USER}"
if id -u "${SB_USER}" >/dev/null 2>&1; then
  log "    已存在"
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "${SB_USER}"
  log "    已创建"
fi

log "2/4 收权限：${DEPLOY_DIR} 归 root:${SB_USER}，目录 750、文件 640"
chown -R "root:${SB_USER}" "${DEPLOY_DIR}"
find "${DEPLOY_DIR}" -type d -exec chmod 750 {} +
find "${DEPLOY_DIR}" -type f -exec chmod 640 {} +
install -d -m 750 -o "${SB_USER}" -g "${SB_USER}" /var/lib/sing-box

log "3/4 写入沙箱单元（${UNIT}）"
if [[ -f "${UNIT}" ]] && ! unit_has NoNewPrivileges; then
  cp -a "${UNIT}" "${UNIT_ORIG}"
  log "    原单元备份到 ${UNIT_ORIG}"
fi
write_unit
systemctl daemon-reload

log "4/4 重启并自检"
systemctl restart sing-box
if verify_running; then
  log "sing-box 以 ${SB_USER} 运行，端口 ${VLESS_PORT}/tcp${ENABLE_HY2:+HY2 已启用时为 ${HY2_PORT}/udp} 正常"
else
  journalctl -u sing-box -n 30 --no-pager >&2 || true
  [[ -f "${UNIT_ORIG}" ]] && rollback
  die "沙箱下服务未就绪，已回滚。多半是某个限制挡了网络或 TUN：删掉对应的 Protect*/SystemCallFilter 行再试"
fi
report
