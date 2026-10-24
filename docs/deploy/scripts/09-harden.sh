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
  --minimal       只做降权（用户 + 三项能力），不加 Protect*/SystemCallFilter
  --check         只报告当前状态，不改任何东西
  --revert        用备份的 .orig 覆盖回去并重启
  -h, --help      显示帮助

改动前会把原 unit 备份到 /etc/systemd/system/sing-box.service.orig，
写入后重启；服务没起来或端口没监听就自动回滚。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --minimal) MODE=minimal ;;
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
  printf '%s\t%s\n' 'FragmentPath' "$(systemctl show -p FragmentPath --value sing-box 2>/dev/null || printf '未加载')"
  printf '%s\t%s\n' 'DropInPaths' "$(systemctl show -p DropInPaths --value sing-box 2>/dev/null || printf '无')"
  printf '%s\t%s\n' '生效 User' "$(systemctl show -p User --value sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' '生效 ReadWritePaths' "$(systemctl show -p ReadWritePaths --value sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' '单元 User' "$(grep -oE '^User=.*' "${UNIT}" 2>/dev/null | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' 'StateDirectory' "$(grep -oE '^StateDirectory=.*' "${UNIT}" 2>/dev/null | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' '运行用户' "$(running_user)"
  printf '%s\t%s\n' '沙箱' "$(unit_has ProtectSystem && printf '完整' || printf '仅降权')"
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
  # 服务 active 不等于端口已绑定：sing-box 起来后还要几十到几百毫秒才 listen。
  # 只查一次会把「还在绑定」误判成失败，进而回滚。
  local _wait=0
  while [[ "${_wait}" -lt 40 ]]; do
    if systemctl is-active --quiet sing-box && port_listening tcp "${VLESS_PORT}"; then
      if [[ "${ENABLE_HY2}" == "1" ]]; then
        port_listening udp "${HY2_PORT}" && return 0
      else
        return 0
      fi
    fi
    sleep 0.5
    _wait=$((_wait + 1))
  done
  printf '端口现状：\n' >&2
  ss -tlnH 2>/dev/null | awk '{print "  tcp " $4}' >&2 || true
  ss -ulnH 2>/dev/null | awk '{print "  udp " $4}' >&2 || true
  return 1
}

rollback() {
  warn "回滚到 ${UNIT_ORIG}"
  restore_run_dir_owner
  cp -a "${UNIT_ORIG}" "${UNIT}"
  systemctl daemon-reload
  systemctl restart sing-box || true
  sleep 1
  if systemctl is-active --quiet sing-box; then
    log "已恢复原单元与 /var/lib/sing-box 属主，服务运行中"
  else
    warn "原单元也没起来，说明问题不在沙箱。最近日志："
    journalctl -u sing-box -n 20 --no-pager 2>&1 | sed 's/^/    /' >&2 || true
    warn "下一步：bash 10-install-singbox.sh 重建单元，再 systemctl restart sing-box"
  fi
}

write_unit() { # $1=full|minimal
  local profile="${1:-full}"
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
# 运行目录由 systemd 建好并 chown 给 User，避免手改属主漏掉
StateDirectory=sing-box
StateDirectoryMode=0750

# ---- 能力：只保留监听低端口、操作 nftables/路由、创建 TUN 所需的三项 ----
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
EOF

  # minimal：到此为止。沙箱指令起不来时先用这一档，确认降权本身没问题
  if [[ "${profile}" == "minimal" ]]; then
    cat >>"${UNIT}" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${UNIT}"
    return 0
  fi

  cat >>"${UNIT}" <<'EOF'

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

# 先停干净：服务若还在 auto-restart 循环，后面的 restart 可能让旧单元先跑一轮，
# 而旧单元以 root 运行、目录此时已归 sing-box，chdir 会失败。
log "2/4 停服务并收权限：${DEPLOY_DIR} 归 root:${SB_USER}，目录 750、文件 640"
systemctl stop sing-box >/dev/null 2>&1 || true
systemctl reset-failed sing-box >/dev/null 2>&1 || true
chown -R "root:${SB_USER}" "${DEPLOY_DIR}"
find "${DEPLOY_DIR}" -type d -exec chmod 750 {} +
find "${DEPLOY_DIR}" -type f -exec chmod 640 {} +
# 20-install.sh 用 install -d -m 700 建的是 root:root，这里必须显式改属主，
# 否则降权后 sing-box 连 chdir 都进不去
install -d -m 750 /var/lib/sing-box
chown -R "${SB_USER}:${SB_USER}" /var/lib/sing-box
chmod 750 /var/lib/sing-box
# 重启前先确认目标用户真能进去，别让服务再重启几十次
if command -v runuser >/dev/null 2>&1; then
  if ! runuser -u "${SB_USER}" -- test -x /var/lib/sing-box; then
    ls -ld /var/lib/sing-box >&2
    namei -l /var/lib/sing-box >&2 || true
    die "${SB_USER} 进不去 /var/lib/sing-box，属主或父目录权限不对，先把上面 ls/namei 的输出看清楚"
  fi
  runuser -u "${SB_USER}" -- test -r "${DEPLOY_DIR}/config.json" \
    || die "${SB_USER} 读不到 ${DEPLOY_DIR}/config.json，检查属主与 640"
fi

log "3/4 写入单元（${UNIT}，模式 ${MODE}）"
if [[ -f "${UNIT}" ]] && ! unit_has NoNewPrivileges; then
  cp -a "${UNIT}" "${UNIT_ORIG}"
  log "    原单元备份到 ${UNIT_ORIG}"
fi
write_unit "${MODE}"
systemctl daemon-reload

log "4/4 重启并自检"
# 服务若还在 auto-restart 循环，直接 restart 可能让旧的待执行任务先跑起来：
# 旧单元是 root，目录此时已归 sing-box，于是 chdir 失败。先停干净再起。
systemctl start sing-box
if ! systemctl is-active --quiet sing-box; then
  # 首次启动偶发 chdir EACCES：清掉失败状态再起一次即可（实测 12 次重启稳定）
  warn "首次启动未成，清状态后重试一次"
  systemctl reset-failed sing-box >/dev/null 2>&1 || true
  systemctl start sing-box
fi
if verify_running; then
  if [[ "${ENABLE_HY2}" == "1" ]]; then
    log "sing-box 以 ${SB_USER} 运行，端口 ${VLESS_PORT}/tcp 与 ${HY2_PORT}/udp 正常"
  else
    log "sing-box 以 ${SB_USER} 运行，端口 ${VLESS_PORT}/tcp 正常"
  fi
else
  journalctl -u sing-box -n 30 --no-pager >&2 || true
  {
    printf '调试信息：\n'
    ls -ld /var/lib/sing-box "${DEPLOY_DIR}" 2>&1
    id "${SB_USER}" 2>&1
  } >&2
  [[ -f "${UNIT_ORIG}" ]] && rollback
  die "服务未就绪，已回滚。先看上面 journal 里的 status=：226/NAMESPACE 是命名空间限制，203/EXEC 是权限或路径，1 加 permission denied 是文件权限。确认降权本身没问题就先用 --minimal"
fi
report
