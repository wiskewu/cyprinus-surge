# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 60（可选）：Hysteria2 端口跳跃
#
# 持久化方式：自建 systemd oneshot 单元，开机执行 iptables 规则。
# 不用 iptables-persistent：Debian 里 ufw 声明了
# Breaks: iptables-persistent, netfilter-persistent，装它会连带把 ufw 卸掉，
# 防火墙随之失效。见 06-ops.html 的说明。
porthop_TITLE="可选：Hysteria2 端口跳跃（iptables 重定向）"
porthop_OPTIONAL=1
PORTHOP_HELPER="/usr/local/sbin/sing-box-porthop"
PORTHOP_UNIT="/etc/systemd/system/sing-box-porthop.service"

porthop_rule_args() {
  PORTHOP_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  PORTHOP_START="${HY2_PORT:-8443}"
  PORTHOP_END="${HY2_HOP_RANGE##*:}"
  [[ -n "${PORTHOP_IFACE}" ]] || return 1
  return 0
}

porthop_check() {
  command -v iptables >/dev/null 2>&1 || return 1
  porthop_rule_args || return 1
  iptables -t nat -C PREROUTING -i "${PORTHOP_IFACE}" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "${PORTHOP_START}" 2>/dev/null
}

porthop_write_helper() {
  cat >"${PORTHOP_HELPER}" <<EOF
#!/bin/sh
# 由 60-porthop.sh 生成，勿手改。systemd 单元 sing-box-porthop.service 调用它。
set -eu
IFACE="${PORTHOP_IFACE}"
START="${PORTHOP_START}"
END="${PORTHOP_END}"
case "\$1" in
  apply)
    iptables -t nat -C PREROUTING -i "\${IFACE}" -p udp --dport "\${START}:\${END}" -j REDIRECT --to-ports "\${START}" 2>/dev/null ||
      iptables -t nat -A PREROUTING -i "\${IFACE}" -p udp --dport "\${START}:\${END}" -j REDIRECT --to-ports "\${START}"
    ;;
  clear)
    iptables -t nat -D PREROUTING -i "\${IFACE}" -p udp --dport "\${START}:\${END}" -j REDIRECT --to-ports "\${START}" 2>/dev/null || true
    ;;
  *)
    printf '用法：%s apply|clear\n' "\$0" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 "${PORTHOP_HELPER}"
}

porthop_write_unit() {
  cat >"${PORTHOP_UNIT}" <<EOF
[Unit]
Description=sing-box Hysteria2 port hop (udp ${PORTHOP_START}:${PORTHOP_END} to ${PORTHOP_START})
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${PORTHOP_HELPER} apply
ExecStop=${PORTHOP_HELPER} clear

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${PORTHOP_UNIT}"
}

porthop_warn_conflict() {
  if dpkg -l iptables-persistent >/dev/null 2>&1 && [[ "$(dpkg -l iptables-persistent | awk '/^ii/{print $1}')" == "ii" ]]; then
    warn "检测到 iptables-persistent。ufw 声明 Breaks: iptables-persistent，两者不能共存"
    warn "  已装它的话 ufw 会被 apt 卸掉。改用本脚本的 systemd 单元后可以移除："
    warn "    sudo apt-get purge -y iptables-persistent netfilter-persistent"
    warn "    sudo apt-get install -y ufw"
  fi
  return 0
}

porthop_run() {
  load_env "${ENVFILE}" 2>/dev/null || true
  [[ "${ENABLE_HY2:-0}" == "1" ]] || {
    warn "ENABLE_HY2=0，跳过端口跳跃"
    return 0
  }
  porthop_rule_args || die "识别不到默认网卡"
  porthop_warn_conflict

  porthop_write_helper
  porthop_write_unit
  systemctl daemon-reload
  systemctl enable sing-box-porthop >/dev/null 2>&1 || true
  systemctl restart sing-box-porthop >/dev/null 2>&1 || true
  if porthop_check; then
    log "端口跳跃生效：udp ${PORTHOP_START}:${PORTHOP_END} → ${PORTHOP_START}（${PORTHOP_IFACE}）"
    log "已持久化：systemd 单元 sing-box-porthop.service，开机自动应用"
  else
    journalctl -u sing-box-porthop -n 10 --no-pager >&2 || true
    die "规则未生效，见上方单元日志"
  fi
}

porthop_uninstall() {
  systemctl disable --now sing-box-porthop >/dev/null 2>&1 || true
  rm -f "${PORTHOP_UNIT}" "${PORTHOP_HELPER}"
  systemctl daemon-reload
  porthop_rule_args || return 0
  iptables -t nat -D PREROUTING -i "${PORTHOP_IFACE}" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "${PORTHOP_START}" 2>/dev/null || true
  log "已移除端口跳跃规则与 systemd 单元"
}
