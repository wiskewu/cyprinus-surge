#!/usr/bin/env bash
# 20-client.sh —— 客户端：装 fwknop、渲染 ~/.fwknoprc、往 ~/.ssh/config 里塞 ProxyCommand。
#   每台机器跑一次，只给它自己那一份密钥（clients/<name>.env）。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

KEYS=""
NAME=""
SSH_CONFIG=1
MODE=deploy
BEGIN="# BEGIN ssh-spa (managed by 20-client.sh)"
END="# END ssh-spa"

usage() {
  cat <<'EOF'
用法：bash 20-client.sh --keys FILE [选项]

  --keys FILE     自己那一份密钥包（00-gen-keys.sh 生成的 clients/<名字>.env）
  --name NAME     覆盖包里的 CLIENT_NAME
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

[ -n "$KEYS" ] || { usage; die "--keys 是必填的"; }

if [ "$MODE" = uninstall ]; then
  strip_block
  if [ -f "$FWKRC" ] && grep -qF '由 20-client.sh 生成' "$FWKRC"; then
    rm -f "$FWKRC"
    log "已删除 $FWKRC"
  fi
  log "卸载完成。密钥包 $KEYS 自己留着或删掉都行"
  exit 0
fi

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
: "${SPA_PORT:=62201}" "${SSH_PORT:=22}" "${ACCESS_TIMEOUT:=120}"
[ -n "${HOSTS:-}" ] || die "密钥包里没有 HOSTS，重新生成或手工加一行 HOSTS=\"名字=地址\""

# 没指定名字、文件里也没有 CLIENT_NAME，就走 SHARED（spa_keys_for 自己会回退）
PAIR="$(spa_keys_for "$KEYS" "${CLIENT_NAME:-}")"
WHO="${CLIENT_NAME:-shared（共用密钥组）}"

log "2/3 渲染 $FWKRC（客户端 $WHO）"
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
  printf 'ALLOW_IP          resolve\n'
  printf 'ACCESS            tcp/%s\n' "$SSH_PORT"
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

# ---------------------------------------------------------------- ~/.ssh/config

if [ "$SSH_CONFIG" = 1 ]; then
  log "3/3 写 $SSHCFG 托管块"
  mkdir -p "$(dirname "$SSHCFG")"; chmod 700 "$(dirname "$SSHCFG")"
  strip_block
  # 备份摘掉托管块之后的版本：备份里不含我们塞的东西
  [ -s "$SSHCFG" ] && cp -a "$SSHCFG" "$SSHCFG.bak"
  {
    cat "$SSHCFG"
    printf '\n%s\n' "$BEGIN"
    for h in $HOSTS; do
      printf 'Host %s\n' "${h%%=*}"
      printf '  HostName %s\n' "${h#*=}"
      # 敲门失败也要往下走：新机器上 fwknop 还没装，nc 会直接连上（那时 22 还开着）
      printf '  ProxyCommand fwknop -n %s >/dev/null 2>&1; sleep 2; nc %%h %%p\n' "${h%%=*}"
    done
    printf '%s\n' "$END"
  } > "$SSHCFG.tmp"
  mv "$SSHCFG.tmp" "$SSHCFG"
  chmod 600 "$SSHCFG"
fi

cat <<EOF

客户端就绪。测一下：
  fwknop -n <主机别名>      # 手动敲一次，服务端 iptables -S FWKNOP_INPUT 会多一条规则
  ssh <主机别名>             # ProxyCommand 里已经带了敲门，感知不到

被自己锁在门外时的急救（本机另开一个终端，不要关掉现在这个）：
  sudo systemctl stop fwknop-server && sudo iptables -D INPUT -j FWKNOP_INPUT
  sudo ufw allow 22/tcp
EOF