# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 55：sing-box 降权与 systemd 沙箱。
#
# 独立入口 09-harden.sh 复用本文件的函数，两条路径行为一致。
# 放在 hy2 之后：沙箱化后要验证 Hy2 端口，证书没装完时 8443 不会监听。
harden_TITLE="sing-box 降权与 systemd 沙箱"
harden_OPTIONAL=0

HARDEN_UNIT="${HARDEN_UNIT:-/etc/systemd/system/sing-box.service}"
HARDEN_UNIT_ORIG="${HARDEN_UNIT}.orig"
SB_USER="${SB_USER:-sing-box}"
HARDEN_PROFILE="${HARDEN_PROFILE:-full}"

harden_env() {
  load_env "${ENVFILE}" 2>/dev/null || true
  VLESS_PORT="${VLESS_PORT:-443}"
  HY2_PORT="${HY2_PORT:-8443}"
  ENABLE_HY2="${ENABLE_HY2:-0}"
}

harden_unit_has() { grep -qE "^$1=" "${HARDEN_UNIT}" 2>/dev/null; }

harden_check() {
  systemctl is-active --quiet sing-box || return 1
  harden_unit_has NoNewPrivileges || return 1
  grep -qE '^User=sing-box' "${HARDEN_UNIT}" 2>/dev/null
}

harden_running_user() {
  local pid
  pid="$(pgrep -x sing-box 2>/dev/null | head -n1 || true)"
  [[ -n "${pid}" ]] || {
    printf '未运行'
    return 0
  }
  ps -o user= -p "${pid}" | tr -d ' '
}

harden_report() {
  printf '%s\t%s\n' '单元文件' "${HARDEN_UNIT}"
  printf '%s\t%s\n' '服务状态' "$(systemctl is-active sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' 'FragmentPath' "$(systemctl show -p FragmentPath --value sing-box 2>/dev/null || printf '未加载')"
  printf '%s\t%s\n' 'DropInPaths' "$(systemctl show -p DropInPaths --value sing-box 2>/dev/null || printf '无')"
  printf '%s\t%s\n' '生效 User' "$(systemctl show -p User --value sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' '生效 ReadWritePaths' "$(systemctl show -p ReadWritePaths --value sing-box 2>/dev/null || printf '未知')"
  printf '%s\t%s\n' '单元 User' "$(grep -oE '^User=.*' "${HARDEN_UNIT}" 2>/dev/null | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' 'StateDirectory' "$(grep -oE '^StateDirectory=.*' "${HARDEN_UNIT}" 2>/dev/null | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' '运行用户' "$(harden_running_user)"
  printf '%s\t%s\n' '沙箱' "$(harden_unit_has ProtectSystem && printf '完整' || printf '仅降权')"
  printf '%s\t%s\n' 'NoNewPrivileges' "$(harden_unit_has NoNewPrivileges && printf 'yes' || printf '未设置')"
  printf '%s\t%s\n' 'ProtectSystem' "$(harden_unit_has ProtectSystem && grep -oE '^ProtectSystem=.*' "${HARDEN_UNIT}" | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' 'CapabilityBoundingSet' "$(harden_unit_has CapabilityBoundingSet && grep -oE '^CapabilityBoundingSet=.*' "${HARDEN_UNIT}" | cut -d= -f2 || printf '未设置')"
  printf '%s\t%s\n' '备份' "$([[ -f "${HARDEN_UNIT_ORIG}" ]] && printf '%s' "${HARDEN_UNIT_ORIG}" || printf '无')"
}

harden_port_listening() { # $1=tcp|udp $2=端口
  if [[ "$1" == tcp ]]; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  else
    ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  fi
}

harden_verify_running() {
  # 服务 active 不等于端口已绑定：sing-box 起来后还要几十到几百毫秒才 listen，
  # 只查一次会把「还在绑定」误判成失败，进而回滚。
  local _wait=0
  while [[ "${_wait}" -lt 40 ]]; do
    if systemctl is-active --quiet sing-box && harden_port_listening tcp "${VLESS_PORT}"; then
      if [[ "${ENABLE_HY2}" == "1" ]]; then
        harden_port_listening udp "${HY2_PORT}" && return 0
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

# 回滚后单元以 root 运行，而运行目录此时归 sing-box、权限 750，root 落到「其他人」，
# chdir 会被拒。恢复单元前先把属主交回 root。
harden_restore_run_dir_owner() {
  [[ -d /var/lib/sing-box ]] || return 0
  chown -R root:root /var/lib/sing-box
  chmod 700 /var/lib/sing-box
}

harden_rollback() {
  warn "回滚到 ${HARDEN_UNIT_ORIG}"
  harden_restore_run_dir_owner || warn "运行目录属主未改回 root，检查 /var/lib/sing-box"
  cp -a "${HARDEN_UNIT_ORIG}" "${HARDEN_UNIT}"
  systemctl daemon-reload
  systemctl restart sing-box || true
  sleep 1
  if systemctl is-active --quiet sing-box; then
    log "已恢复原单元与 /var/lib/sing-box 属主，服务运行中"
  else
    warn "原单元也没起来，问题不在沙箱。最近日志："
    journalctl -u sing-box -n 20 --no-pager 2>&1 | sed 's/^/    /' >&2 || true
    warn "下一步：bash 10-install-singbox.sh 重建单元，再 systemctl restart sing-box"
  fi
}

harden_write_unit() { # $1=full|minimal
  local profile="${1:-full}"
  cat >"${HARDEN_UNIT}" <<EOF
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
    cat >>"${HARDEN_UNIT}" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${HARDEN_UNIT}"
    return 0
  fi

  cat >>"${HARDEN_UNIT}" <<'EOF'

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
  chmod 644 "${HARDEN_UNIT}"
}

harden_run() {
  harden_env
  [[ -x "${SB_BIN}" ]] || die "找不到 ${SB_BIN}，先跑 install 步骤"
  [[ -s "${DEPLOY_DIR}/config.json" ]] || die "缺少 ${DEPLOY_DIR}/config.json，先跑 server 步骤"
  command -v systemctl >/dev/null 2>&1 || die "本步骤按 systemd 写"

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
  # install 步骤用 install -d -m 700 建的是 root:root，这里必须显式改属主，
  # 否则降权后 sing-box 连 chdir 都进不去
  install -d -m 750 /var/lib/sing-box
  chown -R "${SB_USER}:${SB_USER}" /var/lib/sing-box
  chmod 750 /var/lib/sing-box
  # 重启前先确认目标用户真能进去，别让服务再重启几十次
  if command -v runuser >/dev/null 2>&1; then
    if ! runuser -u "${SB_USER}" -- test -x /var/lib/sing-box; then
      ls -ld /var/lib/sing-box >&2
      namei -l /var/lib/sing-box >&2 || true
      die "${SB_USER} 进不去 /var/lib/sing-box，属主或父目录权限不对，先看上面的 ls 与 namei 输出"
    fi
    runuser -u "${SB_USER}" -- test -r "${DEPLOY_DIR}/config.json" \
      || die "${SB_USER} 读不到 ${DEPLOY_DIR}/config.json，检查属主与 640"
  fi

  log "3/4 写入单元（${HARDEN_UNIT}，模式 ${HARDEN_PROFILE}）"
  if [[ -f "${HARDEN_UNIT}" ]] && ! harden_unit_has NoNewPrivileges; then
    cp -a "${HARDEN_UNIT}" "${HARDEN_UNIT_ORIG}"
    log "    原单元备份到 ${HARDEN_UNIT_ORIG}"
  fi
  harden_write_unit "${HARDEN_PROFILE}"
  systemctl daemon-reload

  log "4/4 重启并自检"
  systemctl start sing-box
  if ! systemctl is-active --quiet sing-box; then
    # 首次启动偶发 chdir EACCES：清掉失败状态再起一次
    warn "首次启动未成，清状态后重试一次"
    systemctl reset-failed sing-box >/dev/null 2>&1 || true
    systemctl start sing-box
  fi
  if harden_verify_running; then
    if [[ "${ENABLE_HY2}" == "1" ]]; then
      log "sing-box 以 ${SB_USER} 运行，端口 ${VLESS_PORT}/tcp 与 ${HY2_PORT}/udp 正常"
    else
      log "sing-box 以 ${SB_USER} 运行，端口 ${VLESS_PORT}/tcp 正常"
    fi
    return 0
  fi
  journalctl -u sing-box -n 30 --no-pager >&2 || true
  {
    printf '调试信息：\n'
    ls -ld /var/lib/sing-box "${DEPLOY_DIR}" 2>&1
    id "${SB_USER}" 2>&1
  } >&2
  [[ -f "${HARDEN_UNIT_ORIG}" ]] && harden_rollback
  die "服务未就绪，已回滚。先看上方 journal 里的 status=：226/NAMESPACE 是命名空间限制，203/EXEC 是权限或路径，1 加 permission denied 是文件权限。确认降权本身没问题就先用 HARDEN_PROFILE=minimal 重跑 --only harden"
}

harden_uninstall() {
  if [[ -f "${HARDEN_UNIT_ORIG}" ]]; then
    harden_restore_run_dir_owner || warn "运行目录属主未改回 root，检查 /var/lib/sing-box"
    cp -a "${HARDEN_UNIT_ORIG}" "${HARDEN_UNIT}"
    rm -f "${HARDEN_UNIT_ORIG}"
    systemctl daemon-reload
    systemctl restart sing-box >/dev/null 2>&1 || true
    log "已恢复原单元，sing-box 回到 root 运行"
  else
    log "没有 ${HARDEN_UNIT_ORIG}，单元保持现状"
  fi
}
