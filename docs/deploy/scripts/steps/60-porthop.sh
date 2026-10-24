# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 60（可选）：Hysteria2 端口跳跃
porthop_TITLE="可选：Hysteria2 端口跳跃（iptables 重定向）"
porthop_OPTIONAL=1

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

porthop_run() {
  load_env "${ENVFILE}" 2>/dev/null || true
  [[ "${ENABLE_HY2:-0}" == "1" ]] || {
    warn "ENABLE_HY2=0，跳过端口跳跃"
    return 0
  }
  porthop_rule_args || die "识别不到默认网卡"
  if iptables -t nat -C PREROUTING -i "${PORTHOP_IFACE}" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "${PORTHOP_START}" 2>/dev/null; then
    log "规则已存在"
  else
    iptables -t nat -A PREROUTING -i "${PORTHOP_IFACE}" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "${PORTHOP_START}"
    log "已添加：udp ${PORTHOP_START}:${PORTHOP_END} → ${PORTHOP_START}（${PORTHOP_IFACE}）"
  fi
  export DEBIAN_FRONTEND=noninteractive
  printf '%s\n' "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
  printf '%s\n' "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
  apt-get -y -qq install iptables-persistent >/dev/null
  netfilter-persistent save >/dev/null
  log "已持久化"
}

porthop_uninstall() {
  porthop_rule_args || return 0
  iptables -t nat -D PREROUTING -i "${PORTHOP_IFACE}" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "${PORTHOP_START}" 2>/dev/null || true
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  log "已移除端口跳跃规则"
}
