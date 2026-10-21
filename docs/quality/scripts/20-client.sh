#!/usr/bin/env bash
# 20-client.sh —— 客户端：装 fwknop、渲染 ~/.fwknoprc、往 ~/.ssh/config 里塞 ProxyCommand。
#   每台机器跑一次，只给它自己那一份密钥（clients/<name>.env）。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

KEYS=""
NAME=""
SSH_USER=""
SSH_CONFIG=1
MODE=deploy
BEGIN="# BEGIN ssh-spa (managed by 20-client.sh)"
END="# END ssh-spa"

usage() {
  cat <<'EOF'
用法：bash 20-client.sh --keys FILE [选项]

  --keys FILE     自己那一份密钥包（00-gen-keys.sh 生成的 clients/<名字>.env）
  --name NAME     覆盖包里的 CLIENT_NAME
  --user NAME     写进 ssh config 的登录用户（服务器登录名与本地用户名不同时必须给，比如 root）
  --no-ssh        只写 ~/.fwknoprc，不碰 ~/.ssh/config
  --status        显示当前配置
  --uninstall     还原 ~/.fwknoprc，删掉 ~/.ssh/config 里的托管块
  -h, --help      显示帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --keys) shift; KEYS="${1:?--keys 需要参数}" ;;
    --keys=*) KEYS="${1#*=}" ;;
    --name) shift; NAME="${1:?--name 需要参数}" ;;
    --name=*) NAME="${1#*=}" ;;
    --user) shift; SSH_USER="${1:?--user 需要参数}" ;;
    --user=*) SSH_USER="${1#*=}" ;;
    --no-ssh) SSH_CONFIG=0 ;;
    --status) MODE=status ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

FWKRC="${FWKRC:-$HOME/.fwknoprc}"
SSHCFG="${SSHCFG:-$HOME/.ssh/config}"

strip_block() {  # 从 ~/.ssh/config 里摘掉托管块，并清掉末尾多余空行（否则重跑会越积越多）
  [ -f "$SSHCFG" ] || return 0
  local tmp="$SSHCFG.spa.tmp"
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$SSHCFG" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$tmp" && mv "$tmp" "$SSHCFG"
}

if [ "$MODE" = status ]; then
  printf '%s : %s\n' "$FWKRC" "$([ -f "$FWKRC" ] && echo 存在 || echo 不存在)"
  [ -f "$FWKRC" ] && grep -E '^\[' "$FWKRC" | tr -d '[]' | sed 's/^/  stanza: /'
  grep -qF "$BEGIN" "$SSHCFG" 2>/dev/null && echo "$SSHCFG : 托管块存在" || echo "$SSHCFG : 无托管块"
  exit 0
fi

[ -z "$SSH_USER" ] || valid_name "$SSH_USER" || die "登录用户名不合法：$SSH_USER"

# --uninstall 是纯清理，不需要密钥包：少了 --keys 也让它跑
if [ "$MODE" = uninstall ]; then
  strip_block
  if [ -f "$FWKRC" ] && grep -qF '由 20-client.sh 生成' "$FWKRC"; then
    rm -f "$FWKRC"
    log "已删除 $FWKRC"
  fi
  log "卸载完成。密钥包 ${KEYS:-（未指定）} 自己留着或删掉都行"
  exit 0
fi

[ -n "$KEYS" ] || { usage; die "--keys 是必填的"; }

# ---------------------------------------------------------------- 安装

log "1/3 安装 fwknop"
if ! command -v fwknop >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install fwknop >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fwknop-client >/dev/null
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm fwknop >/dev/null
  else
    die "没找到 fwknop，手工装一个（Debian/Ubuntu: apt install fwknop-client）"
  fi
fi
command -v fwknop >/dev/null 2>&1 || die "fwknop 装完仍找不到"
command -v nc >/dev/null 2>&1 || warn "没有 nc，ProxyCommand 里的最后一步会失败（Debian/Ubuntu: apt install netcat-openbsd）"

# ---------------------------------------------------------------- 渲染 ~/.fwknoprc

load_env "$KEYS"
[ -n "$NAME" ] && { valid_name "$NAME" || die "客户端名不合法：$NAME"; CLIENT_NAME="$NAME"; }
: "${SPA_PORT:=62201}" "${ACCESS_TIMEOUT:=120}"
# SSH_PORT 不给默认值：填错的话 SPA 会去开一个 sshd 根本不在的端口，表现是
# 「敲门成功但连不上」，且很难查。这个值由服务端 10-server.sh 探测后写进 client.env。
[ -n "${SSH_PORT:-}" ] || die "$KEYS 里没有 SSH_PORT。用服务端 10-server.sh 处理过的那份 client.env（SSH_PORT 由它探测写入）；确认无误再手工加一行 SSH_PORT=你的端口"
# sshd 可能同时监听多个端口（比如刚挪端口那阵 22 与 4061 并存），服务端探测到的是一串，
# 写回密钥包时也带引号成 "22 4061"。fwknop 的 ACCESS 语法是逗号分隔，不是空格。
ACCESS_PORTS=""
for _p in $SSH_PORT; do
  case "$_p" in
    '' | *[!0-9]*) die "SSH_PORT 里不是一个端口：'$_p'（密钥包里应当是 SSH_PORT=22 或 SSH_PORT=\"22 4061\"）" ;;
  esac
  ACCESS_PORTS="${ACCESS_PORTS:+$ACCESS_PORTS,}tcp/$_p"
done
unset _p
[ -n "${HOSTS:-}" ] || die "密钥包里没有 HOSTS，重新生成或手工加一行 HOSTS=\"名字=地址\""

# ALLOW_IP 三选一（对应 fwknop 的 -s / -R / -a）：
#   source  → 包里写 0.0.0.0，服务端按「包从哪个 IP 来」放行。不需要 wget
#   resolve → 客户端经 wget 查自己的公网 IP（macOS 默认没装 wget：会只打一行
#             "Use --wget-cmd ..."，包根本没发出去）
#   <IP>    → 写死 IP，最抗 MITM，但换网络就得改
# 默认 source：漫游 / 家宽 IP 会变时这是唯一不需要额外依赖的做法。
# 想换：密钥包里写一行 ALLOW_IP=…，或跑脚本时 ALLOW_IP=… 。
ALLOW_IP_MODE="${ALLOW_IP:-source}"
case "$ALLOW_IP_MODE" in
  source | resolve) ;;
  *[!0-9A-Za-z.:-]*) die "ALLOW_IP 只能是 source / resolve / 一个 IP：$ALLOW_IP_MODE" ;;
esac

# 没指定名字、文件里也没有 CLIENT_NAME，就走 SHARED（spa_keys_for 自己会回退）
PAIR="$(spa_keys_for "$KEYS" "${CLIENT_NAME:-}")"
WHO="${CLIENT_NAME:-shared（共用密钥组）}"

# 本机开着 TUN/VPN 时，到服务器的流量会被隧道接走：敲门包的源 IP 会变成隧道出口，
# 而 TUN 在本地就把 TCP 握手接住了，于是出现「nc 能通、ssh 立刻被关」的假象。
# 这里只提醒，不改任何东西——修法是在代理配置里把服务器 IP 设为直连。
warn_if_tunneled() {
  local h ip iface
  for h in $HOSTS; do
    ip="${h#*=}"
    case "$ip" in *[!0-9.]*) continue ;; esac   # 只判断纯 IPv4：域名要解析，结果不稳
    iface=""
    if command -v route >/dev/null 2>&1; then        # macOS / BSD
      iface="$(route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2; exit}')"
    elif command -v ip >/dev/null 2>&1; then         # Linux
      iface="$(ip route get "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    fi
    case "${iface:-}" in
      utun* | tun* | wg* | ipsec*)
        warn "到 $ip 的流量走的是 ${iface}（本机 TUN / VPN）"
        warn "  后果：敲门包源 IP 变成隧道出口（ALLOW_IP source 会对不上）；SSH 也可能被隧道绕死"
        warn "  症状：nc 能通但 ssh 立刻被关（TUN 在本地就接了握手，那个「通」是假的）"
        warn "  谁在持有这个网卡（规则必须加在那个客户端里，改别人的配置没用）："
        warn "    pgrep -fl 'clash|mihomo|sing-box|surge|stash'"
        warn "  解法（配置层面，别去改本机 route）：把 $ip 设为直连"
        warn "    sing-box: route.rules 顶部加 { \"ip_cidr\": [\"$ip/32\"], \"action\": \"route\", \"outbound\": \"direct\" }"
        warn "    Clash/Mihomo: IP-CIDR,$ip/32,DIRECT（多数 GUI 会自动加，命令行配置要手写）"
        ;;
    esac
  done
  return 0
}
warn_if_tunneled

log "2/3 渲染 ${FWKRC}（客户端 ${WHO}）"
umask 077
# fwknop 装完会丢一个全注释的样例，只有那类文件值得备份；我们生成的版本不用备
[ -f "$FWKRC" ] && ! grep -qF '由 20-client.sh 生成' "$FWKRC" && cp -a "$FWKRC" "$FWKRC.bak"
{
  printf '# 由 20-client.sh 生成，勿手改。重跑脚本即可更新。\n'
  printf '# 客户端 %s（服务端在 access.conf 里按这把密钥逐个 stanza 试）\n\n' "$WHO"
  printf '[default]\n'
  printf 'SPA_SERVER_PROTO  udp\n'
  printf 'USE_HMAC          Y\n'
  printf 'HMAC_DIGEST_TYPE  SHA512\n'
  printf 'ALLOW_IP          %s\n' "$ALLOW_IP_MODE"
  printf 'ACCESS            %s\n' "$ACCESS_PORTS"
  printf 'KEY_BASE64        %s\n' "${PAIR%%:*}"
  printf 'HMAC_KEY_BASE64   %s\n' "${PAIR##*:}"
  for h in $HOSTS; do
    printf '\n[%s]\n' "${h%%=*}"
    printf 'SPA_SERVER        %s\n' "${h#*=}"
    printf 'SPA_SERVER_PORT   %s\n' "$SPA_PORT"
  done
} > "$FWKRC"
chmod 600 "$FWKRC"

# 自检：写完的文件要含每个主机 stanza，且密钥对只有一个冒号
for h in $HOSTS; do
  grep -qF "[${h%%=*}]" "$FWKRC" || die "自检失败：$FWKRC 里少了 stanza ${h%%=*}"
done
case "$PAIR" in
  *:*) ;;
  *) die "自检失败：密钥对格式不对" ;;
esac

# 下面的提示文案要用：第一个主机名与第一个 SSH 端口
FIRST_HOST="$(printf '%s\n' $HOSTS | head -n1)"
FIRST_HOST="${FIRST_HOST%%=*}"
# 多端口时优先挑一个非 22 的（SSH_PORT 可能是 "22 4061"）；只有 22 才退回它
FIRST_PORT=""
for _p in $SSH_PORT; do
  case "$_p" in
    22) [ -n "$FIRST_PORT" ] || FIRST_PORT=22 ;;
    *) FIRST_PORT="$_p"; break ;;
  esac
done
[ -n "$FIRST_PORT" ] || FIRST_PORT="${SSH_PORT%% *}"

# ---------------------------------------------------------------- ~/.ssh/config

if [ "$SSH_CONFIG" = 1 ]; then
  log "3/3 写 $SSHCFG 托管块"
  mkdir -p "$(dirname "$SSHCFG")"; chmod 700 "$(dirname "$SSHCFG")"
  strip_block
  # 备份摘掉托管块之后的版本：备份里不含我们塞的东西
  [ -s "$SSHCFG" ] && cp -a "$SSHCFG" "$SSHCFG.bak"
  {
    # 首次配置时 ~/.ssh/config 可能还不存在；分隔行追加在末尾，否则每重跑一次就多一个空行
    if [ -f "$SSHCFG" ]; then cat "$SSHCFG"; printf '\n'; fi
    printf '%s\n' "$BEGIN"
    for h in $HOSTS; do
      printf 'Host %s\n' "${h%%=*}"
      printf '  HostName %s\n' "${h#*=}"
      # 不写 User 的话 ssh 会用本机用户名登录，服务器上没有同名账号时只会看到
      # Permission denied (publickey)——很像「SPA 又坏了」，其实只是用户名不对。
      [ -n "$SSH_USER" ] && printf '  User %s\n' "$SSH_USER"
      # ssh 默认端口是 22；用探测到的那个（优先非 22：22 常被 RST 注入/被服务商拦）
      [ "$FIRST_PORT" != "22" ] && printf '  Port %s\n' "$FIRST_PORT"
      # 【必须】包一层 sh -c：ssh 会把 ProxyCommand 改写成 "exec <命令>"，
      # 于是 "exec fwknop ...; sleep 2; nc ..." 里的 sleep 和 nc 永远不会执行——
      # 症状是握手前就 EOF：Connection closed by UNKNOWN port 65535。
      printf '  ProxyCommand /bin/sh -c '"'"'fwknop -n %s >/dev/null 2>&1; sleep 2; exec nc %%h %%p'"'"'\n' "${h%%=*}"
    done
    printf '%s\n' "$END"
  } > "$SSHCFG.tmp"
  mv "$SSHCFG.tmp" "$SSHCFG"
  chmod 600 "$SSHCFG"
fi

cat <<EOF

客户端就绪。测一下（下面用第一个主机、第一个 SSH 端口举例）：
  fwknop -n ${FIRST_HOST} -v     # 手动敲一次；服务端 sudo iptables -S FWKNOP_INPUT 会多一条规则
  ssh -p ${FIRST_PORT} ${FIRST_HOST}$([ "$FIRST_PORT" = 22 ] && printf '   # 端口是 22 时 -p 可省')
                                # ProxyCommand 里已经带了敲门，感知不到

ssh 仍不通时，先分清是「敲门没到」还是「端口不通」：
  服务端：sudo journalctl -u fwknop-server -n 20      # 有没有 SPA 包、有没有 ACCEPT
  服务端：sudo iptables -S FWKNOP_INPUT              # 有没有为你的 IP 开端口
  本机：  nc -vz <服务器IP> ${FIRST_PORT}              # 能连上但立刻断 → 多半是 fail2ban 封了你

被自己锁在门外时的急救（本机另开一个终端，不要关掉现在这个）：
  sudo systemctl stop fwknop-server && sudo iptables -D INPUT -j FWKNOP_INPUT
  sudo ufw allow ${FIRST_PORT}/tcp
EOF