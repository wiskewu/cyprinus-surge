#!/usr/bin/env bash
# 10-server.sh —— 服务端：装 fwknopd、渲染 access.conf、收掉公网 SSH 规则。
#   幂等：重跑只补齐缺失部分。--close-ssh 是单独一步，避免把管理员锁在门外。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
need_root

FWK_DIR="${FWK_DIR:-/etc/fwknop}"
FWD_CONF="$FWK_DIR/fwknopd.conf"
ACCESS_CONF="$FWK_DIR/access.conf"
FWD_ORIG="$FWK_DIR/fwknopd.conf.orig"
KEYS="spa-keys.env"
CLOSE_SSH=0
PURGE=0
MODE=deploy

usage() {
  cat <<'EOF'
用法：sudo bash 10-server.sh [选项]

  --keys FILE       00-gen-keys.sh 生成的密钥包（默认 ./spa-keys.env）
  --close-ssh       删掉公网 SSH 防火墙规则。确认能从客户端敲门进来之后再加这个参数
  --status          只看状态，不改任何东西
  --uninstall       停 fwknopd、还原 fwknopd.conf、恢复公网 SSH 规则（保留密钥包）
  --purge           --uninstall + 删除 access.conf 和密钥包
  -h, --help        显示帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --keys) shift; KEYS="${1:?--keys 需要参数}" ;;
    --keys=*) KEYS="${1#*=}" ;;
    --close-ssh) CLOSE_SSH=1 ;;
    --status) MODE=status ;;
    --uninstall) MODE=uninstall ;;
    --purge) MODE=uninstall; PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

# ---------------------------------------------------------------- 状态

show_status() {
  printf '包      : %s\n' "$KEYS"
  if command -v fwknopd >/dev/null 2>&1; then
    printf 'fwknopd : %s\n' "$(systemctl is-active fwknop-server 2>/dev/null || echo 未安装)"
    printf '跳转规则: %s\n' "$(iptables -S INPUT 2>/dev/null | grep -q FWKNOP_INPUT && echo '在 INPUT 第 1 位（正常）' || echo '缺失 —— 跑 systemctl restart fwknop-server，或检查 ufw 是否重载过')"
    printf '当前放行: %s\n' "$(iptables -S FWKNOP_INPUT 2>/dev/null | grep -c '^-A' || true) 条临时规则"
  else
    printf 'fwknopd : 未安装\n'
  fi
  if command -v ufw >/dev/null 2>&1; then
    printf 'ufw     : %s\n' "$(ufw status | head -1)"
    ufw status | grep -E "22/tcp|62201/udp" | sed 's/^/          /' || true
  fi
}

if [ "$MODE" = status ]; then show_status; exit 0; fi

# ---------------------------------------------------------------- 卸载

if [ "$MODE" = uninstall ]; then
  systemctl disable --now fwknop-server >/dev/null 2>&1 || true
  [ -f "$FWD_ORIG" ] && { mv "$FWD_ORIG" "$FWD_CONF"; log "已还原 fwknopd.conf"; }
  [ "$PURGE" = 1 ] && { rm -f "$ACCESS_CONF" "$KEYS"; log "已删除 access.conf 与密钥包"; }
  if command -v ufw >/dev/null 2>&1; then
    ufw --force delete allow 62201/udp >/dev/null 2>&1 || true
    ufw limit 22/tcp >/dev/null 2>&1 || true
    log "已恢复公网 SSH 规则（ufw limit 22/tcp）"
  fi
  exit 0
fi

# ---------------------------------------------------------------- 部署

need_cmd openssl
command -v apt-get >/dev/null 2>&1 || die "本脚本按 Debian/Ubuntu 写的；其他发行版请照 README 手工改"

log "1/5 安装 fwknop-server"
if ! command -v fwknopd >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fwknop-server >/dev/null
fi
command -v fwknopd >/dev/null 2>&1 || die "fwknopd 装完仍找不到，检查 apt 输出"

load_env "$KEYS"
: "${SPA_PORT:=62201}" "${SSH_PORT:=22}" "${ACCESS_TIMEOUT:=120}" "${MAX_FW_TIMEOUT:=300}"

IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
[ -n "$IFACE" ] || die "识别不到默认网卡，PCAP_INTF 只能靠 fwknopd 自己猜，指定网卡再跑"

# ---- 渲染 fwknopd.conf：只写我们要管的几项，其余用包自带默认值 ----
log "2/5 渲染 $FWD_CONF（网卡 $IFACE，SPA 端口 $SPA_PORT）"
mkdir -p "$FWK_DIR"
[ -f "$FWD_ORIG" ] || { [ -f "$FWD_CONF" ] && cp -a "$FWD_CONF" "$FWD_ORIG"; }
cat > "$FWD_CONF" <<EOF
# 由 10-server.sh 生成，勿手改。包自带版本备份在 $FWD_ORIG
PCAP_INTF                $IFACE;
PCAP_FILTER              udp port $SPA_PORT;

FLUSH_IPT_AT_INIT        Y;
FLUSH_IPT_AT_EXIT        Y;
ENABLE_IPT_COMMENT_CHECK Y;

# 防重放：时间戳 + 摘要缓存（进程重启后仍认得旧包）
ENABLE_SPA_PACKET_AGING  Y;
MAX_SPA_PACKET_AGE       120;
ENABLE_DIGEST_PERSISTENCE Y;

# 跳转规则插在 INPUT 第 1 位，因此在 ufw 的链之前求值：SPA 开的口子不会被 ufw 挡掉
IPT_INPUT_ACCESS         ACCEPT, filter, INPUT, 1, FWKNOP_INPUT, 1;
ENABLE_IPT_FORWARDING    N;
ENABLE_IPT_SNAT          N;
ENABLE_IPT_OUTPUT        N;
ENABLE_IPT_LOCAL_NAT     N;

SYSLOG_ID                fwknopd;
EOF
chmod 644 "$FWD_CONF"

# ---- 渲染 access.conf：一个客户端一个 stanza ----
# fwknopd 会依次尝试每个 stanza，用各自的密钥解密；只有对上的那个能开规则
# （server/incoming_spa.c: incoming_spa() 里的 while(acc) 循环）。所以所有 stanza
# 都可以写 SOURCE ANY，靠密钥区分客户端。
log "3/5 渲染 $ACCESS_CONF"
umask 077
render_stanza() {
  printf 'SOURCE ANY;\n'
  printf 'OPEN_PORTS tcp/%s;\n' "$SSH_PORT"
  printf 'FW_ACCESS_TIMEOUT %s;\n' "$ACCESS_TIMEOUT"
  printf 'MAX_FW_TIMEOUT %s;\n' "$MAX_FW_TIMEOUT"
  printf 'KEY_BASE64 %s;\n' "${1%%:*}"
  printf 'HMAC_KEY_BASE64 %s;\n' "${1##*:}"
  printf '\n'
}

{
  printf '# 由 10-server.sh 从 %s 渲染，勿手改。\n' "$KEYS"
  printf '# 每个 stanza 一台客户端：删掉一行就是吊销那台设备。\n\n'
  n=0
  if [ -n "${SHARED:-}" ]; then
    n=$((n+1))
    printf '# --- shared（共用密钥组）---\n'
    render_stanza "$SHARED"
  fi
  for entry in ${CLIENTS:-}; do
    n=$((n+1))
    printf '# --- %s ---\n' "${entry%%=*}"
    render_stanza "${entry#*=}"
  done
  [ "$n" -gt 0 ] || die "密钥包里没有 SHARED 也没有 CLIENTS"
} > "$ACCESS_CONF"
chmod 600 "$ACCESS_CONF"

# 自检：渲染出来的 stanza 数必须等于密钥包里的密钥组数
want=$(host_count "${CLIENTS:-}")
[ -n "${SHARED:-}" ] && want=$((want+1))
got="$(grep -c '^KEY_BASE64 ' "$ACCESS_CONF" || true)"
[ "$got" = "$want" ] || die "自检失败：access.conf 渲染出 $got 个 stanza，期望 $want 个"

# ---- 起服务 ----
log "4/5 启动 fwknopd"
systemctl enable fwknop-server >/dev/null 2>&1 || true
systemctl restart fwknop-server
sleep 1
systemctl is-active --quiet fwknop-server || {
  journalctl -u fwknop-server -n 20 --no-pager >&2
  die "fwknopd 起不来（多半是配置语法错）。SSH 规则还没动，可以直接看上面的日志"
}
iptables -S INPUT | grep -q FWKNOP_INPUT || die "fwknopd 在跑但没有创建 FWKNOP_INPUT 跳转，检查 $FWD_CONF 的 PCAP_INTF"

# ---- 防火墙 ----
log "5/5 防火墙"
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$SPA_PORT/udp" >/dev/null
  log "已放行 $SPA_PORT/udp"
  if [ "$CLOSE_SSH" = 1 ]; then
    ufw --force delete limit "$SSH_PORT/tcp" >/dev/null 2>&1 || true
    ufw --force delete allow "$SSH_PORT/tcp" >/dev/null 2>&1 || true
    log "已删除公网 $SSH_PORT/tcp 规则"
  else
    log "保持公网 $SSH_PORT/tcp 规则（确认客户端能进门后跑 --close-ssh）"
  fi
  # ufw 的 enable/reload/reset 会重建 INPUT 链，把 fwknopd 的跳转冲掉 → 重启让它插回去
  systemctl restart fwknop-server
  sleep 1
  iptables -S INPUT | grep -q FWKNOP_INPUT || warn "重启后跳转规则仍不在，确认 iptables 是不是 nft 后端"
else
  warn "没装 ufw，跳过防火墙改动。自己确认 $SPA_PORT/udp 通，且 $SSH_PORT/tcp 不对公网开放"
fi

cat <<EOF

服务端就绪。下一步：
  1) 在客户端跑 20-client.sh 配好 ~/.fwknoprc
  2) 先在当前这个 SSH 会话里另开一个连接试：ssh <别名>
     确认能进来，再跑：bash 10-server.sh --keys $KEYS --close-ssh
  3) 从外网验一遍：nmap -Pn -p$SSH_PORT <服务器IP>   → 必须显示 filtered
EOF