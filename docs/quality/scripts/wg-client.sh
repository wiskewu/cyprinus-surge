#!/usr/bin/env bash
# wg-client.sh —— 在服务器上生成客户端配置，或查看、吊销对端。
#
#   sudo bash wg-client.sh --add laptop        生成 laptop 的配置并写进 wg0
#   sudo bash wg-client.sh --list              列出对端与握手时间
#   sudo bash wg-client.sh --show laptop       重新打印配置与二维码
#   sudo bash wg-client.sh --remove laptop     吊销对端并删除配置
#   sudo bash wg-client.sh --check             只校验配置一致性
#
# 生成物落在 /etc/wireguard/clients/<名字>.conf，含该设备的私钥，
# 权限 600。客户端配置只路由管理网段，不影响默认路由与其他代理。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/wg-lib.sh
. "${SELF_DIR}/wg-lib.sh"

MODE=""
NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --add) shift; MODE=add; NAME="${1:?--add 需要名字}" ;;
    --show) shift; MODE=show; NAME="${1:?--show 需要名字}" ;;
    --remove) shift; MODE=remove; NAME="${1:?--remove 需要名字}" ;;
    --list) MODE=list ;;
    --check) MODE=check ;;
    -h | --help)
      cat <<'EOF'
用法：sudo bash wg-client.sh <动作>

  --add NAME     生成设备配置并写入 wg0，输出配置路径与二维码
  --show NAME    重新打印已有配置
  --remove NAME  吊销对端，删除配置与记录
  --list         列出全部对端、地址与最近握手
  --check        校验 wg0、密钥、配置三者一致
  -h, --help     显示帮助

环境变量：WG_PORT（默认 443）、WG_ENDPOINT（默认取本机公网 IPv4）
EOF
      exit 0
      ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

[[ -n "${MODE}" ]] || die "缺少动作，见 --help"
need_root

valid_name() { [[ "${1}" =~ ^[A-Za-z0-9._-]+$ ]]; }

# 隧道里 sshd 仍在非 22 端口，直接 ssh 10.66.0.1 会连 22 并超时。
ssh_hint() {
  local name="${1}" port
  port="$(ssh_port)"
  printf '\n客户端连入的命令：ssh -p %s root@%s\n' "${port}" "${WG_NET}"
  printf '写入 ~/.ssh/config 可以省掉端口：\n'
  printf '  Host %s\n    HostName %s\n    Port %s\n    User root\n' "${name}" "${WG_NET}" "${port}"
}
endpoint_ip() {
  if [[ -n "${WG_ENDPOINT:-}" ]]; then
    printf '%s' "${WG_ENDPOINT}"
    return 0
  fi
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  [[ -n "${ip}" ]] || ip="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [[ -n "${ip}" ]] || die "识别不到公网 IPv4，用 WG_ENDPOINT= 指定"
  printf '%s' "${ip}"
}

case "${MODE}" in
  list)
    wg_up || die "wg0 未运行"
    wg show "${WG_IF}"
    ;;
  check)
    wg_up || die "wg0 未运行"
    bad=0
    while IFS= read -r pub; do
      [[ -n "${pub}" ]] || continue
      grep -q "${pub}" "${WG_CONF}" || {
        warn "运行中的对端 ${pub:0:8}… 不在 ${WG_CONF} 里"
        bad=1
      }
    done < <(wg show "${WG_IF}" peers)
    [[ "${bad}" == 0 ]] && log "wg0 对端与 ${WG_CONF} 一致"
    ;;
  show)
    conf="${WG_DIR}/clients/${NAME}.conf"
    [[ -f "${conf}" ]] || die "没有 ${conf}"
    cat "${conf}"
    if command -v qrencode >/dev/null 2>&1; then
      printf '\n'
      qrencode -t ansiutf8 <"${conf}"
    fi
    ;;
  remove)
    valid_name "${NAME}" || die "名字只允许字母数字 . _ -"
    pub_file="${WG_DIR}/peers/${NAME}.pub"
    [[ -f "${pub_file}" ]] || die "没有 ${NAME} 的记录"
    pub="$(cat "${pub_file}")"
    wg set "${WG_IF}" peer "${pub}" remove 2>/dev/null || true
    # 整段删除该对端的 [Peer] 块：只删 PublicKey 那几行会留下空 [Peer]，
    # wg-quick 会报 "A peer is missing a public key" 并拒绝启动。
    awk -v k="${pub}" '
      function flush() { if (buf != "" && !drop) printf "%s", buf; buf = ""; drop = 0 }
      /^\[Peer\]/ { flush(); buf = $0 "\n"; inpeer = 1; next }
      { if (inpeer) { buf = buf $0 "\n"; if ($0 == "PublicKey = " k) drop = 1 } else print }
      END { flush() }
    ' "${WG_CONF}" >"${WG_CONF}.tmp" && mv "${WG_CONF}.tmp" "${WG_CONF}"
    rm -f "${pub_file}" "${WG_DIR}/clients/${NAME}.conf" "${WG_DIR}/peers/${NAME}.ip"
    log "已吊销 ${NAME}（${pub:0:8}…）"
    ;;
  add)
    valid_name "${NAME}" || die "名字只允许字母数字 . _ -"
    wg_up || die "wg0 未运行，先跑 wg-server.sh"
    if [[ -f "${WG_DIR}/peers/${NAME}.pub" ]]; then
      rec_pub="$(cat "${WG_DIR}/peers/${NAME}.pub")"
      if grep -q "PublicKey = ${rec_pub}" "${WG_CONF}"; then
        die "${NAME} 已存在，先 --remove 再新增"
      fi
      # 记录还在但 wg0.conf 里没有这段：上次删除只清了文件，按新增重建
      warn "${NAME} 的记录残留但不在 ${WG_CONF} 里，按新增重建"
      rm -f "${WG_DIR}/peers/${NAME}.pub" "${WG_DIR}/peers/${NAME}.ip" "${WG_DIR}/clients/${NAME}.conf"
    fi
    ip="$(next_client_ip)" || die "管理网段地址用尽"
    umask 077
    priv="$(wg genkey)"
    pub="$(printf '%s' "${priv}" | wg pubkey)"
    psk="$(wg genpsk)"
    {
      printf '\n[Peer]\n'
      printf '# %s\n' "${NAME}"
      printf 'PublicKey = %s\n' "${pub}"
      printf 'PresharedKey = %s\n' "${psk}"
      printf 'AllowedIPs = %s/32\n' "${ip}"
    } >>"${WG_CONF}"
    wg set "${WG_IF}" peer "${pub}" preshared-key <(printf '%s' "${psk}") allowed-ips "${ip}/32"
    printf '%s\n' "${pub}" >"${WG_DIR}/peers/${NAME}.pub"
    printf '%s\n' "${ip}" >"${WG_DIR}/peers/${NAME}.ip"
    {
      printf '[Interface]\n'
      printf 'PrivateKey = %s\n' "${priv}"
      printf 'Address = %s/32\n' "${ip}"
      printf 'DNS = \n'
      printf '\n[Peer]\n'
      printf 'PublicKey = %s\n' "$(cat "${WG_DIR}/server.pub")"
      printf 'PresharedKey = %s\n' "${psk}"
      printf 'Endpoint = %s:%s\n' "$(endpoint_ip)" "${WG_PORT}"
      printf 'AllowedIPs = %s\n' "${WG_CIDR}"
      printf 'PersistentKeepalive = 25\n'
    } >"${WG_DIR}/clients/${NAME}.conf"
    chmod 600 "${WG_DIR}/clients/${NAME}.conf"
    sed -i '/^DNS = $/d' "${WG_DIR}/clients/${NAME}.conf"
    log "已添加 ${NAME}：地址 ${ip}，配置 ${WG_DIR}/clients/${NAME}.conf"
    ssh_hint "${NAME}"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ansiutf8 <"${WG_DIR}/clients/${NAME}.conf"
    else
      printf '安装 qrencode 可在这里直接显示二维码：apt-get install qrencode\n'
    fi
    ;;
esac
