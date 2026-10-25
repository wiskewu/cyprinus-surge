#!/usr/bin/env bash
# wg-selfcheck.sh —— 自动验收 WireGuard 管理内网。
#
#   sudo bash wg-selfcheck.sh               跑全部检查，有失败项则退出码 1
#   sudo bash wg-selfcheck.sh --expect-closed  额外要求公网 SSH 已关闭
#
# 第三项检查会临时建一个网络命名空间，用一个一次性对端从 veth 走真实的
# UDP 路径连到 wg0，再从隧道里连 sshd 并读取 SSH 标识。检查结束自动清理，
# 不会留下接口、命名空间或对端。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/wg-lib.sh
. "${SELF_DIR}/wg-lib.sh"

EXPECT_CLOSED=0
[[ "${1:-}" == "--expect-closed" ]] && EXPECT_CLOSED=1

SSH_P="$(ssh_port)"
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

need_root
command -v wg >/dev/null 2>&1 || die "未安装 wireguard-tools"
command -v ip >/dev/null 2>&1 || die "缺少 iproute2"

printf '== 1. wg0 接口 ==\n'
if wg_up; then
  ok "wg0 已启动"
else
  bad "wg0 未启动：systemctl status wg-quick@${WG_IF}"
fi
LISTEN="$(wg show "${WG_IF}" listen-port 2>/dev/null || true)"
if [[ "${LISTEN}" == "${WG_PORT}" ]]; then
  ok "监听端口 ${WG_PORT}/udp"
else
  bad "监听端口是 ${LISTEN:-未知}，期望 ${WG_PORT}"
fi
ADDR="$(ip -4 -o addr show "${WG_IF}" 2>/dev/null | awk '{print $4}')"
if [[ "${ADDR}" == "${WG_ADDR}" ]]; then
  ok "地址 ${WG_ADDR}"
else
  bad "地址是 ${ADDR:-无}，期望 ${WG_ADDR}"
fi
PEERS="$(wg show "${WG_IF}" peers 2>/dev/null | grep -c . || true)"
if [[ "${PEERS}" -ge 1 ]]; then
  ok "已登记 ${PEERS} 个对端"
else
  bad "没有任何对端"
fi

printf '== 2. 防火墙 ==\n'
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q "^${WG_PORT}/udp[[:space:]]*ALLOW"; then
    ok "${WG_PORT}/udp 已放行"
  else
    bad "${WG_PORT}/udp 未放行"
  fi
  if ufw status | grep -qE "^${SSH_P}/tcp on ${WG_IF}[[:space:]]*ALLOW"; then
    ok "SSH 允许从 ${WG_IF} 进入"
  else
    bad "缺少 ${WG_IF} 上的 SSH 放行规则"
  fi
  if ufw status | grep -qE "^${SSH_P}/tcp[[:space:]]+(ALLOW|LIMIT)"; then
    if [[ "${EXPECT_CLOSED}" == 1 ]]; then
      bad "公网 ${SSH_P}/tcp 仍然放行"
    else
      ok "公网 ${SSH_P}/tcp 仍放行（迁移期允许）"
    fi
  else
    ok "公网 ${SSH_P}/tcp 已关闭"
  fi
else
  bad "没有 ufw"
fi

printf '== 3. 隧道端到端（临时对端 + 命名空间）==\n'
NS="wgselfcheck$$"
VETH_H="wgscheck$$"
VETH_N="wgsnp$$"
cleanup() {
  ip netns del "${NS}" >/dev/null 2>&1 || true
  ip link del "${VETH_H}" >/dev/null 2>&1 || true
  if [[ -n "${TMP_PUB:-}" ]]; then
    wg set "${WG_IF}" peer "${TMP_PUB}" remove >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

TMP_PRIV="$(wg genkey)"
TMP_PUB="$(printf '%s' "${TMP_PRIV}" | wg pubkey)"
SERVER_PUB="$(cat "${WG_DIR}/server.pub")"
CLIENT_IP="10.66.0.250"

ip netns add "${NS}"
ip link add "${VETH_H}" type veth peer name "${VETH_N}"
ip link set "${VETH_N}" netns "${NS}"
ip addr add 169.254.10.1/30 dev "${VETH_H}"
ip link set "${VETH_H}" up
ip netns exec "${NS}" ip link set lo up
ip netns exec "${NS}" ip addr add 169.254.10.2/30 dev "${VETH_N}"
ip netns exec "${NS}" ip link set "${VETH_N}" up

wg set "${WG_IF}" peer "${TMP_PUB}" allowed-ips "${CLIENT_IP}/32"
printf '%s' "${TMP_PRIV}" >"/tmp/${NS}.key"
chmod 600 "/tmp/${NS}.key"
ip netns exec "${NS}" ip link add wgtest type wireguard
ip netns exec "${NS}" wg set wgtest private-key "/tmp/${NS}.key" \
  peer "${SERVER_PUB}" endpoint 169.254.10.1:"${WG_PORT}" allowed-ips "${WG_CIDR}"
rm -f "/tmp/${NS}.key"
ip netns exec "${NS}" ip addr add "${CLIENT_IP}/32" dev wgtest
ip netns exec "${NS}" ip link set wgtest up
ip netns exec "${NS}" ip route add "${WG_CIDR}" dev wgtest

if ip netns exec "${NS}" timeout 8 bash -c "exec 3<>/dev/tcp/${WG_NET}/${SSH_P} && head -c 40 <&3" >/tmp/wgselfcheck.banner 2>/dev/null; then
  BANNER="$(tr -d '\r\n' </tmp/wgselfcheck.banner)"
  case "${BANNER}" in
    SSH-*) ok "经隧道连上 ${WG_NET}:${SSH_P}，SSH 标识 ${BANNER}" ;;
    *) bad "连上了 ${WG_NET}:${SSH_P}，但返回的不是 SSH 标识：${BANNER}" ;;
  esac
else
  bad "经隧道连不上 ${WG_NET}:${SSH_P}"
fi
rm -f /tmp/wgselfcheck.banner
if wg show "${WG_IF}" latest-handshakes 2>/dev/null | grep -q "${TMP_PUB}"; then
  HS="$(wg show "${WG_IF}" latest-handshakes | awk -v k="${TMP_PUB}" '$1 == k {print $2}')"
  if [[ "${HS}" != "0" ]]; then
    ok "临时对端完成握手"
  else
    bad "临时对端未完成握手"
  fi
else
  bad "临时对端没有登记到 wg0"
fi

printf '== 4. 结论 ==\n'
printf '  通过 %d 项，失败 %d 项\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]] || exit 1
