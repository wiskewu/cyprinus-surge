# 步骤 30：生成密钥与两份环境文件
secrets_TITLE="生成密钥（deploy.env / client.env）"
secrets_OPTIONAL=0

secrets_check() {
  [ -s "$ENVFILE" ] && [ -s "$CLIENT_ENV" ]
}

secrets_run() {
  local UUID KP SERVER_IP="$SERVER_IP"
  : "${REALITY_DEST:=www.apple.com}"
  : "${DOMAIN:=}"
  : "${ENABLE_HY2:=0}"
  : "${AI_MODE:=main}"

  if [ -n "${SERVER_IP:-}" ]; then
    :
  else
    SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$SERVER_IP" ] || SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  [ -n "$SERVER_IP" ] || die "无法识别公网 IPv4，请用 SERVER_IP=x.x.x.x 指定"

  if [ -z "${NONINTERACTIVE:-}" ]; then
    printf '\n可直接回车使用方括号里的默认值。\n'
    local _in
    read -r -p "伪装站点 REALITY_DEST [${REALITY_DEST}]（需支持 TLS1.3+H2）: " _in; REALITY_DEST="${_in:-$REALITY_DEST}"
    read -r -p "域名 DOMAIN [${DOMAIN:-留空}]（只有 Hysteria2 需要）: " _in; DOMAIN="${_in:-$DOMAIN}"
    if [ -n "$DOMAIN" ]; then
      read -r -p "启用 Hysteria2？[Y/n]: " _in
      case "${_in:-y}" in y|Y) ENABLE_HY2=1 ;; *) ENABLE_HY2=0 ;; esac
    else
      ENABLE_HY2=0
    fi
  fi

  UUID="$("$SB_BIN" generate uuid)"
  KP="$("$SB_BIN" generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$KP" | awk -F': *' '/PrivateKey/{print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$KP" | awk -F': *' '/PublicKey/{print $2}')"
  SHORT_ID="$(openssl rand -hex 4)"
  HY2_PASSWORD="$(rand_pass 20)"
  OBFS_PASSWORD="$(rand_pass 20)"
  [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "REALITY 密钥生成失败"

  umask 077
  cat >"$ENVFILE" <<ENV
# ===== 服务器环境（含私钥，勿外传）=====
SERVER_IP=$SERVER_IP
SSH_PORT=${SSH_PORT:-22}
VLESS_PORT=${VLESS_PORT:-443}
REALITY_DEST=$REALITY_DEST
UUID=$UUID
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
SHORT_ID=$SHORT_ID

ENABLE_HY2=$ENABLE_HY2
DOMAIN=$DOMAIN
HY2_PORT=${HY2_PORT:-8443}
HY2_HOP_RANGE=${HY2_HOP_RANGE:-8443:8447}
HY2_UP_MBPS=${HY2_UP_MBPS:-100}
HY2_DOWN_MBPS=${HY2_DOWN_MBPS:-300}
HY2_PASSWORD=$HY2_PASSWORD
OBFS_PASSWORD=$OBFS_PASSWORD

AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-false}
AI_MODE=$AI_MODE
AI_SOCKS_SERVER=${AI_SOCKS_SERVER:-}
AI_SOCKS_PORT=${AI_SOCKS_PORT:-1080}
AI_SOCKS_USER=${AI_SOCKS_USER:-}
AI_SOCKS_PASS=${AI_SOCKS_PASS:-}
CLIENT_MIXED=${CLIENT_MIXED:-1}
ENV

  cat >"$CLIENT_ENV" <<ENV
# ===== 客户端环境（复制到 Windows / macOS / Android）=====
SERVER_IP=$SERVER_IP
VLESS_PORT=${VLESS_PORT:-443}
REALITY_SERVER_NAME=$REALITY_DEST
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
SHORT_ID=$SHORT_ID
UUID=$UUID

ENABLE_HY2=$ENABLE_HY2
DOMAIN=$DOMAIN
HY2_PORT=${HY2_PORT:-8443}
HY2_HOP_RANGE=${HY2_HOP_RANGE:-8443:8447}
HY2_PASSWORD=$HY2_PASSWORD
OBFS_PASSWORD=$OBFS_PASSWORD

AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-false}
AI_MODE=$AI_MODE
AI_SOCKS_SERVER=${AI_SOCKS_SERVER:-}
AI_SOCKS_PORT=${AI_SOCKS_PORT:-1080}
AI_SOCKS_USER=${AI_SOCKS_USER:-}
AI_SOCKS_PASS=${AI_SOCKS_PASS:-}
CLIENT_MIXED=${CLIENT_MIXED:-1}
ENV
  chmod 600 "$ENVFILE" "$CLIENT_ENV"
  chown root:root "$ENVFILE" "$CLIENT_ENV"

  log "已生成：$ENVFILE / $CLIENT_ENV"
  printf '\n  服务器 IP    %s\n  端口         %s/tcp\n  伪装站点     %s\n  UUID         %s\n  REALITY 公钥 %s\n  short_id     %s\n' \
    "$SERVER_IP" "${VLESS_PORT:-443}" "$REALITY_DEST" "$UUID" "$REALITY_PUBLIC_KEY" "$SHORT_ID"
}

secrets_uninstall() {
  if [ "${PURGE:-0}" = "1" ]; then
    rm -f "$ENVFILE" "$CLIENT_ENV"
    log "已删除 deploy.env / client.env"
  else
    log "保留 deploy.env / client.env（如需删除：--purge）"
  fi
}
