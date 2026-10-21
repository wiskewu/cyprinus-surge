#!/usr/bin/env bash
# 90-uninstall.sh —— 退出 SPA 加固：回到「公网 SSH 能直连、不再敲门」的状态。
#
#   sudo bash 90-uninstall.sh                # 服务器：先开公网 SSH，再拆掉 SPA
#   bash 90-uninstall.sh --client            # 客户端：还原 ~/.fwknoprc 与 ~/.ssh/config
#   sudo bash 90-uninstall.sh --check         # 只看现在是什么状态，什么都不改
#   加 --purge 顺便删 access.conf / 密钥包（服务端）或本地那份 client 密钥（客户端）
#
# 为什么单独做一个脚本，而不是让人手敲 iptables：
#   收口之后公网 SSH 规则是不存在的，只有 FWKNOP_INPUT 那条临时规则在放行。
#   所以拆的顺序必须是「先开公网 SSH 并回读确认 → 再停 fwknopd」，
#   反过来（10-server.sh --uninstall 的顺序）中间那一小段时间里没有任何规则放行 SSH，
#   万一 ufw 那步静默失败，你就只能靠云控制台回来了。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

MODE=server
CHECK=0
PURGE=0
KEYS="./spa-keys.env"

FWK_DIR="${FWK_DIR:-/etc/fwknop}"
FWD_CONF="$FWK_DIR/fwknopd.conf"
FWD_ORIG="$FWK_DIR/fwknopd.conf.orig"
ACCESS_CONF="$FWK_DIR/access.conf"

usage() {
  cat <<'EOF'
用法：sudo bash 90-uninstall.sh [选项]        # 服务端（默认）
      bash 90-uninstall.sh --client [选项]    # 客户端

  --check        只打印当前状态，不改任何东西
  --client       客户端模式：还原 ~/.fwknoprc，摘掉 ~/.ssh/config 的托管块
  --purge        服务端连 access.conf + 密钥包一起删；客户端连那份 client 密钥一起删
  --keys FILE    密钥包路径（默认 ./spa-keys.env，只用来读 SPA_PORT 与 --purge）
  -h, --help     显示帮助

服务端做的事（顺序有讲究）：
  1) 先 ufw 放行探测到的每一个 SSH 端口，并回读确认
  2) 停用 fwknop-server
  3) 删掉 INPUT 里的 FWKNOP_INPUT 跳转与链
  4) 关掉 SPA 端口（udp）
  5) 还原 fwknopd.conf（保留 .orig 备份的那份原配置）
  6) 打印最终状态，ufw / sshd / ssh 直连三项自检
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --client) MODE=client ;;
    --server) MODE=server ;;
    --check | --status) CHECK=1 ;;
    --purge) PURGE=1 ;;
    --keys) shift; KEYS="${1:?--keys 需要参数}" ;;
    --keys=*) KEYS="${1#*=}" ;;
    -h | --help) usage; exit 0 ;;
    *) usage; die "未知参数：$1" ;;
  esac
  shift
done

# ---------------------------------------------------------------- 客户端

run_client() {
  [ -x "$SELF_DIR/20-client.sh" ] || [ -f "$SELF_DIR/20-client.sh" ] ||
    die "找不到同目录下的 20-client.sh（客户端还原靠它，别手改 ~/.fwknoprc）"
  if [ "$CHECK" = 1 ]; then
    bash "$SELF_DIR/20-client.sh" --status || true
    [ -f "${KEYS:-}" ] && printf '密钥包 : %s（--purge 会删掉它）\n' "$KEYS"
    return 0
  fi
  bash "$SELF_DIR/20-client.sh" --uninstall
  log "客户端托管块与 ~/.fwknoprc 已还原"
  if [ "$PURGE" = 1 ]; then
    if [ -f "$KEYS" ]; then rm -f "$KEYS"; log "已删除本地密钥包 $KEYS"; fi
    warn "服务端那份密钥包（spa-keys.env / access.conf）不受影响，需要的话去服务器上跑 --purge"
  else
    warn "本地密钥包还在（${KEYS}）。确认不再用就 bash 90-uninstall.sh --client --purge --keys $KEYS"
  fi
  cat <<'EOF'

客户端已退出 SPA。之后连服务器：

  ssh <别名>            # ~/.ssh/config 里那条 ProxyCommand 已经不在了，直连
  第一次会走你原来的登录方式（公钥 / 密码，看服务器当前配置）

若服务器那边还是「只认 SPA」，直连会被挡——先在服务器上跑：sudo bash 90-uninstall.sh
EOF
}

[ "$MODE" = client ] && { run_client; exit 0; }

# ---------------------------------------------------------------- 服务端

spa_port() {
  local v=""
  [ -f "$KEYS" ] && v="$(grep -E '^SPA_PORT=' "$KEYS" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "\"' ")" || true
  case "$v" in '' | *[!0-9]*) printf '62201' ;; *) printf '%s' "$v" ;; esac
}

SPA_PORT="$(spa_port)"

show_status() {
  printf 'fwknopd    : %s\n' "$(command -v fwknopd >/dev/null 2>&1 && (systemctl is-active fwknop-server 2>/dev/null || echo 未知) || echo 未安装)"
  printf 'INPUT 跳转 : %s\n' "$(iptables -S INPUT 2>/dev/null | grep -q FWKNOP_INPUT && echo '在（SPA 仍在接管）' || echo '不在（SPA 未接管）')"
  printf '临时放行   : %s 条\n' "$(iptables -S FWKNOP_INPUT 2>/dev/null | grep -c '^-A' || true)"
  local ports; ports="$(ssh_resolve_ports 2>/dev/null || true)"
  printf 'SSH 端口   : %s\n' "${ports:-（探测不到，用 SSH_PORT= 指定）}"
  if command -v ufw >/dev/null 2>&1; then
    printf 'ufw        : %s\n' "$(ufw status | head -1)"
    ufw status | grep -E "($(printf '%s' "${ports:-22}" | tr ' ' '|'))/tcp|${SPA_PORT}/udp" | sed 's/^/             /' || true
  fi
}

if [ "$CHECK" = 1 ]; then
  [ "$(id -u)" = 0 ] || warn "非 root：iptables / ufw 的信息可能读不到（加 sudo 更完整）"
  show_status
  exit 0
fi

need_root

# 1) 先开公网 SSH —— 这一步不成功就绝不继续拆
PORTS="$(ssh_resolve_ports)"
log "1/6 先放行公网 SSH：${PORTS}/tcp"
if command -v ufw >/dev/null 2>&1; then
  for p in $PORTS; do ufw allow "$p/tcp" comment 'ssh' >/dev/null; done
  # 回读：ufw 加规则也是「写进去不等于生效」，只看退出码会误判
  missing=""
  for p in $PORTS; do
    ufw status | grep -qE "^${p}/tcp[[:space:]]+(ALLOW|LIMIT)" || missing="$missing $p"
  done
  [ -z "$missing" ] || die "ufw 里这些 SSH 端口没放行成：${missing}。SPA 还完整，先去排查（别继续拆）"
  log "    已确认 ufw 放行了：${PORTS}/tcp"
else
  warn "没有 ufw，跳过放行（没有防火墙就等于本来就直连）"
fi

# 2) 停 fwknopd
log "2/6 停用 fwknop-server"
systemctl disable --now fwknop-server >/dev/null 2>&1 || warn "    fwknop-server 停用失败，继续（后面会清 iptables）"

# 3) 清 iptables：跳转 + 链
log "3/6 删除 INPUT 跳转与 FWKNOP_INPUT 链"
iptables -D INPUT -j FWKNOP_INPUT 2>/dev/null || true
iptables -F FWKNOP_INPUT 2>/dev/null || true
iptables -X FWKNOP_INPUT 2>/dev/null || true
iptables -S INPUT 2>/dev/null | grep -q FWKNOP_INPUT && warn "    INPUT 里还有 FWKNOP_INPUT 跳转，手工删一下"

# 4) 关 SPA 端口
log "4/6 关闭 SPA 端口 ${SPA_PORT}/udp"
if command -v ufw >/dev/null 2>&1; then
  ufw --force delete allow "${SPA_PORT}/udp" >/dev/null 2>&1 || true
  ufw status | grep -q "${SPA_PORT}/udp" && warn "    ufw 里还能看到 ${SPA_PORT}/udp，手工删一下"
fi

# 5) 还原 fwknopd.conf
log "5/6 还原 fwknopd.conf"
if [ -f "$FWD_ORIG" ]; then
  mv "$FWD_ORIG" "$FWD_CONF"
  log "    已从 ${FWD_ORIG} 还原"
else
  warn "    没有 ${FWD_ORIG}，fwknopd.conf 保持现状（服务已停，不影响直连）"
fi

# 6) 自检
log "6/6 自检"
show_status
printf '\n'
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  if sshd -T >/dev/null 2>&1; then
    log "sshd 配置可解析；公网可直接连：${PORTS}/tcp"
  else
    warn "sshd -T 报错，先修 sshd 再看"
  fi
fi
cat <<EOF

已退出 SPA 加固。现在的状态：公网 SSH 直连、不再需要敲门。

还需要你手工收尾的：
  1) fail2ban 与密码登录策略没动过：sshd -T | grep -i '^passwordauthentication' 确认仍是 no
  2) 密钥包与 access.conf 还留着（access.conf 里是各设备的 SPA 密钥）：
     $ACCESS_CONF$([ "$PURGE" = 1 ] && echo '（--purge 已删除）')
     $KEYS$([ "$PURGE" = 1 ] && echo '（--purge 已删除）')
  3) 每台客户端的 ~/.fwknoprc 与 ~/.ssh/config 托管块要各自清：
     bash 90-uninstall.sh --client --keys <那份 client .env>
  4) 想再打开 SPA：sudo bash 10-server.sh --keys <密钥包>
EOF

if [ "$PURGE" = 1 ]; then
  rm -f "$ACCESS_CONF" "$KEYS"
  log "已删除 access.conf 与密钥包"
fi
