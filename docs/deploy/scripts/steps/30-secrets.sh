# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 30：生成密钥与两份环境文件
secrets_TITLE="生成密钥（deploy.env / client.env / devices.list）"
secrets_OPTIONAL=0

secrets_check() {
  [[ -s "$ENVFILE" ]] && [[ -s "$CLIENT_ENV" ]] && [[ -s "$DEVICES_LIST" ]]
}

secrets_run() {
  local SERVER_IP="$SERVER_IP"
  mkdir -p "$DEPLOY_DIR"
  : "${REALITY_DEST:=www.apple.com}"
  : "${DOMAIN:=}"
  : "${ENABLE_HY2:=0}"
  : "${AI_MODE:=main}"

  if [[ -n "${SERVER_IP:-}" ]]; then
    :
  else
    SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$SERVER_IP" ]] || SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  [[ -n "$SERVER_IP" ]] || die "无法识别公网 IPv4，请用 SERVER_IP=x.x.x.x 指定"

  if [[ -z "${NONINTERACTIVE:-}" ]]; then
    printf '\n可直接回车使用方括号里的默认值。\n'
    local _in
    read -r -p "伪装站点 REALITY_DEST [${REALITY_DEST}]（需支持 TLS1.3+H2）: " _in; REALITY_DEST="${_in:-$REALITY_DEST}"
    read -r -p "入口域名 DOMAIN [${DOMAIN:-留空}]（留空则客户端连公网 IP；启用 Hysteria2 时必填）: " _in; DOMAIN="${_in:-$DOMAIN}"
    if [[ -n "$DOMAIN" ]]; then
      read -r -p "启用 Hysteria2？[Y/n]: " _in
      case "${_in:-y}" in y|Y) ENABLE_HY2=1 ;; *) ENABLE_HY2=0 ;; esac
    else
      ENABLE_HY2=0
    fi
    read -r -p "第一台设备的名字 [main]: " _in; FIRST_DEVICE="${_in:-main}"
  else
    FIRST_DEVICE="${FIRST_DEVICE:-main}"
  fi
  valid_device_name "$FIRST_DEVICE" || die "设备名不合法：${FIRST_DEVICE}（只允许字母数字 . _ -）"

  KP="$("$SB_BIN" generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$KP" | awk -F': *' '/PrivateKey/{print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$KP" | awk -F': *' '/PublicKey/{print $2}')"
  SHORT_ID="$(openssl rand -hex 4)"
  OBFS_PASSWORD="$(rand_pass 20)"
  [[ -n "$REALITY_PRIVATE_KEY" ]] && [[ -n "$REALITY_PUBLIC_KEY" ]] || die "REALITY 密钥生成失败"

  # 设备名单已存在就原样保留：凭据不该因为重跑 secrets 而全变一遍。
  # 现有实例里的 devices.list 优先，Force 重跑也不覆盖。
  if [[ ! -s "$DEVICES_LIST" ]]; then
    umask 077
    cat >"$DEVICES_LIST" <<LIST
# ssh-sp 设备名单 —— 每行「名字 凭据 平台」，删一行 = 吊销那台设备（两条入口同时失效）
# 凭据同时当 VLESS 的 uuid 和 Hysteria2 的 password 用，保证吊销是原子的
$FIRST_DEVICE $("$SB_BIN" generate uuid) desktop
LIST
    chmod 600 "$DEVICES_LIST"
    log "已创建设备名单：${DEVICES_LIST}（第一台：${FIRST_DEVICE}）"
  else
    log "设备名单已存在，保留：$DEVICES_LIST"
  fi

  # client.env 里的 UUID / HY2_PASSWORD 是 devices.list 首行的镜像，
  # 让「在客户端机器上手动渲染单份」的老用法继续可用；日常以 devices.list 为准。
  local first_cred
  first_cred="$(device_get "$FIRST_DEVICE" 2>/dev/null | awk '{print $1}')" \
    || first_cred="$(device_rows | head -1 | awk '{print $2}')"
  [[ -n "$first_cred" ]] || die "设备名单读不出凭据：$DEVICES_LIST"

  # 节点地址：域名优先，留空就用公网 IP
  SERVER_HOST="$DOMAIN"
  [[ -n "$SERVER_HOST" ]] || SERVER_HOST="$SERVER_IP"

  umask 077
  cat >"$ENVFILE" <<ENV
# ===== 服务器环境（含私钥，勿外传）=====
SERVER_IP=$SERVER_IP
SSH_PORT=${SSH_PORT:-22}
VLESS_PORT=${VLESS_PORT:-443}
REALITY_DEST=$REALITY_DEST
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
SHORT_ID=$SHORT_ID

ENABLE_HY2=$ENABLE_HY2
DOMAIN=$DOMAIN
HY2_PORT=${HY2_PORT:-8443}
HY2_HOP_RANGE=${HY2_HOP_RANGE:-8443:8447}
HY2_UP_MBPS=${HY2_UP_MBPS:-100}
HY2_DOWN_MBPS=${HY2_DOWN_MBPS:-300}
OBFS_PASSWORD=$OBFS_PASSWORD

# 桌面端默认 true：TUN 开着时，auto_detect_interface 负责把出站绑定到物理网卡，
# 否则 direct 出站会按默认路由又走回 tun（环），表现为「连上立刻被断」。
# 只有在 Windows 多网卡报 "not valid in its context" 时才关掉，并且要同时指定
# 网卡（客户端脚本支持 DEFAULT_INTERFACE=en0 之类）。
AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-true}
AI_MODE=$AI_MODE
AI_SOCKS_SERVER=${AI_SOCKS_SERVER:-}
AI_SOCKS_PORT=${AI_SOCKS_PORT:-1080}
AI_SOCKS_USER=${AI_SOCKS_USER:-}
AI_SOCKS_PASS=${AI_SOCKS_PASS:-}
CLIENT_MIXED=${CLIENT_MIXED:-1}
ENV

  cat >"$CLIENT_ENV" <<ENV
# ===== 客户端环境（单份渲染时用；多设备请在服务端用 device.sh 直接生成）=====
SERVER_IP=$SERVER_IP
SERVER_HOST=$SERVER_HOST
VLESS_PORT=${VLESS_PORT:-443}
REALITY_SERVER_NAME=$REALITY_DEST
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
SHORT_ID=$SHORT_ID
UUID=$first_cred

ENABLE_HY2=$ENABLE_HY2
DOMAIN=$DOMAIN
HY2_PORT=${HY2_PORT:-8443}
HY2_HOP_RANGE=${HY2_HOP_RANGE:-8443:8447}
HY2_PASSWORD=$first_cred
OBFS_PASSWORD=$OBFS_PASSWORD

# 桌面端默认 true：TUN 开着时，auto_detect_interface 负责把出站绑定到物理网卡，
# 否则 direct 出站会按默认路由又走回 tun（环），表现为「连上立刻被断」。
# 只有在 Windows 多网卡报 "not valid in its context" 时才关掉，并且要同时指定
# 网卡（客户端脚本支持 DEFAULT_INTERFACE=en0 之类）。
AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-true}
AI_MODE=$AI_MODE
AI_SOCKS_SERVER=${AI_SOCKS_SERVER:-}
AI_SOCKS_PORT=${AI_SOCKS_PORT:-1080}
AI_SOCKS_USER=${AI_SOCKS_USER:-}
AI_SOCKS_PASS=${AI_SOCKS_PASS:-}
CLIENT_MIXED=${CLIENT_MIXED:-1}
ENV
  chmod 600 "$ENVFILE" "$CLIENT_ENV" "$DEVICES_LIST"
  # root:root 在真实服务器上有效；某些环境（如容器）没这个组，失败也不影响 0600 权限
  chown root:root "$ENVFILE" "$CLIENT_ENV" 2>/dev/null || true

  log "已生成：$ENVFILE / $CLIENT_ENV / $DEVICES_LIST"
  printf '\n  服务器 IP    %s\n  节点地址     %s%s\n  端口         %s/tcp\n  伪装站点     %s\n  设备数       %s\n  REALITY 公钥 %s\n  short_id     %s\n' \
    "$SERVER_IP" "$SERVER_HOST" "$([ "$SERVER_HOST" = "$SERVER_IP" ] && echo '（未配域名）' || echo '（域名）')" \
    "${VLESS_PORT:-443}" "$REALITY_DEST" "$(device_rows | wc -l)" "$REALITY_PUBLIC_KEY" "$SHORT_ID"
}

secrets_uninstall() {
  if [[ "${PURGE:-0}" == "1" ]]; then
    rm -f "$ENVFILE" "$CLIENT_ENV" "$DEVICES_LIST"
    log "已删除 deploy.env / client.env / devices.list"
  else
    log "保留 deploy.env / client.env / devices.list（如需删除：--purge）"
  fi
}
