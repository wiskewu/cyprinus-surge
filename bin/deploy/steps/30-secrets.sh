# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 30：生成密钥与两份环境文件
secrets_TITLE="生成密钥（deploy.env / client.env / devices.list）"
secrets_OPTIONAL=0

secrets_check() {
  [[ -s "${ENVFILE}" ]] && [[ -s "${CLIENT_ENV}" ]] && [[ -s "${DEVICES_LIST}" ]]
}

# 是否换新客户端可见的密钥（REALITY 密钥对、short_id、HY2 混淆密码）。
# 参数 --rotate-secrets 优先；否则在真 TTY 上问一句，问不到（非交互）就沿用。
# 返回值：0=换新，1=沿用。
# 单独成函数是为了能在无 TTY 的环境里用桩替换来验证调用方逻辑。
secrets_decide_rotate() {
  [[ "${OPT_ROTATE_SECRETS:-0}" == "1" ]] && return 0
  [[ -z "${NONINTERACTIVE:-}" ]] || return 1
  [[ -t 0 ]] || return 1
  local ans="" ans2=""
  printf '\n%s 里已有 REALITY 密钥对与 HY2 混淆密码。\n' "${ENVFILE}" >&2
  read -r -p "沿用（已导出的客户端配置继续有效）？[Y/n]: " ans || true
  case "${ans:-y}" in
    n | N) ;;
    *) return 1 ;;
  esac
  # 换新会作废所有已分发配置，二次确认：回车、误敲都不至于把客户端全废掉
  printf '换新会更换 REALITY 密钥对、short_id 与 HY2 混淆密码，\n' >&2
  printf '已导出的客户端会全部连不上，需要逐台重新 export。\n' >&2
  read -r -p "确认换新？[y/N]: " ans2 || true
  case "${ans2:-n}" in
    y | Y) return 0 ;;
    *) return 1 ;;
  esac
}

secrets_run() {
  local SERVER_IP="${SERVER_IP}"
  ensure_deploy_dir
  : "${REALITY_DEST:=www.apple.com}"
  : "${DOMAIN:=}"
  : "${ENABLE_HY2:=0}"
  : "${AI_MODE:=main}"

  if [[ -n "${SERVER_IP:-}" ]]; then
    :
  else
    SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "${SERVER_IP}" ]] || SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  [[ -n "${SERVER_IP}" ]] || die "无法识别公网 IPv4，请用 SERVER_IP=x.x.x.x 指定"

  if [[ -z "${NONINTERACTIVE:-}" ]]; then
    printf '\n可直接回车使用方括号里的默认值。\n'
    local _in
    read -r -p "伪装站点 REALITY_DEST [${REALITY_DEST}]（需支持 TLS1.3+H2）: " _in
    REALITY_DEST="${_in:-${REALITY_DEST}}"
    read -r -p "入口域名 DOMAIN [${DOMAIN:-留空}]（留空则客户端连公网 IP；启用 Hysteria2 时必填）: " _in
    DOMAIN="${_in:-${DOMAIN}}"
    if [[ -n "${DOMAIN}" ]]; then
      read -r -p "启用 Hysteria2？[Y/n]: " _in
      case "${_in:-y}" in y | Y) ENABLE_HY2=1 ;; *) ENABLE_HY2=0 ;; esac
    else
      ENABLE_HY2=0
    fi
    read -r -p "第一台设备的名字 [main]: " _in
    FIRST_DEVICE="${_in:-main}"
  else
    FIRST_DEVICE="${FIRST_DEVICE:-main}"
  fi
  valid_device_name "${FIRST_DEVICE}" || die "设备名不合法：${FIRST_DEVICE}（只允许字母数字 . _ -）"

  # REALITY 公钥、short_id 与 HY2 混淆密码都嵌在已经导出的客户端配置里。换掉
  # 它们等于作废所有客户端，而错误只在客户端表现为 REALITY 校验失败或 QUIC
  # 握手失败。默认沿用 deploy.env 里的旧值；换新要用参数 --rotate-secrets，
  # 交互模式下每次都会问一句，不静默决定。
  local old_priv="" old_pub="" old_sid="" old_obfs="" reuse_reality=1
  if [[ "${OPT_ROTATE_SECRETS:-0}" != "1" ]] && [[ -f "${ENVFILE}" ]]; then
    old_priv="$(sed -n 's/^REALITY_PRIVATE_KEY=//p' "${ENVFILE}" | head -1)"
    old_pub="$(sed -n 's/^REALITY_PUBLIC_KEY=//p' "${ENVFILE}" | head -1)"
    old_sid="$(sed -n 's/^SHORT_ID=//p' "${ENVFILE}" | head -1)"
    old_obfs="$(sed -n 's/^OBFS_PASSWORD=//p' "${ENVFILE}" | head -1)"
  fi
  if [[ -n "${old_priv}" ]] && [[ -n "${old_pub}" ]] && [[ -n "${old_sid}" ]]; then
    # 沿用与否都改变已分发配置的可用性，交互时问一句，不静默决定
    secrets_decide_rotate && reuse_reality=0
  else
    reuse_reality=0
  fi
  if [[ "${reuse_reality}" == "1" ]]; then
    REALITY_PRIVATE_KEY="${old_priv}"
    REALITY_PUBLIC_KEY="${old_pub}"
    SHORT_ID="${old_sid}"
    log "沿用已有 REALITY 密钥对、short_id 与 HY2 混淆密码（换新：--rotate-secrets，之后所有设备需重新 export）"
  else
    KP="$("${SB_BIN}" generate reality-keypair)"
    REALITY_PRIVATE_KEY="$(printf '%s\n' "${KP}" | awk -F': *' '/PrivateKey/{print $2}')"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "${KP}" | awk -F': *' '/PublicKey/{print $2}')"
    SHORT_ID="$(openssl rand -hex 4)"
    [[ -n "${REALITY_PRIVATE_KEY}" ]] && [[ -n "${REALITY_PUBLIC_KEY}" ]] || die "REALITY 密钥生成失败"
  fi
  if [[ "${reuse_reality}" == "1" ]] && [[ -n "${old_obfs}" ]]; then
    OBFS_PASSWORD="${old_obfs}"
  else
    OBFS_PASSWORD="$(rand_pass 20)"
  fi

  # 设备名单已存在就原样保留：凭据不该因为重跑 secrets 而全变一遍。
  # 现有实例里的 devices.list 优先，Force 重跑也不覆盖。
  if [[ ! -s "${DEVICES_LIST}" ]]; then
    umask 077
    cat >"${DEVICES_LIST}" <<LIST
# ssh-sp 设备名单 —— 每行「名字 凭据 平台」，删一行 = 吊销那台设备（两条入口同时失效）
# 凭据同时当 VLESS 的 uuid 和 Hysteria2 的 password 用，保证吊销是原子的
${FIRST_DEVICE} $("${SB_BIN}" generate uuid) desktop
LIST
    chmod 600 "${DEVICES_LIST}"
    log "已创建设备名单：${DEVICES_LIST}（第一台：${FIRST_DEVICE}）"
  else
    log "设备名单已存在，保留：${DEVICES_LIST}"
  fi

  # client.env 里的 UUID / HY2_PASSWORD 是 devices.list 首行的镜像，
  # 让「在客户端机器上手动渲染单份」的老用法继续可用；日常以 devices.list 为准。
  local first_cred
  first_cred="$(device_get "${FIRST_DEVICE}" 2>/dev/null | awk '{print $1}')" \
    || first_cred="$(device_rows | head -1 | awk '{print $2}')"
  [[ -n "${first_cred}" ]] || die "设备名单读不出凭据：${DEVICES_LIST}"

  # 节点地址：域名优先，留空就用公网 IP
  SERVER_HOST="${DOMAIN}"
  [[ -n "${SERVER_HOST}" ]] || SERVER_HOST="${SERVER_IP}"

  # SSH_PORT 只写真实端口。写成 ${SSH_PORT:-22} 这样的占位默认值，会让防火墙步骤
  # 把 22 当成「用户额外要求放行的端口」，即使 sshd 早已不在 22 上监听。
  local ssh_port="${SSH_PORT:-}"
  [[ -n "${ssh_port}" ]] || ssh_port="$(detect_ssh_ports 2>/dev/null | awk '{print $1}')"

  umask 077
  cat >"${ENVFILE}" <<ENV
# ===== 服务器环境（含私钥，勿外传）=====
SERVER_IP=${SERVER_IP}
SSH_PORT=${ssh_port}
VLESS_PORT=${VLESS_PORT:-443}
REALITY_DEST=${REALITY_DEST}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
SHORT_ID=${SHORT_ID}

ENABLE_HY2=${ENABLE_HY2}
DOMAIN=${DOMAIN}
HY2_PORT=${HY2_PORT:-8443}
HY2_HOP_RANGE=${HY2_HOP_RANGE:-8443:8447}
HY2_UP_MBPS=${HY2_UP_MBPS:-100}
HY2_DOWN_MBPS=${HY2_DOWN_MBPS:-300}
OBFS_PASSWORD=${OBFS_PASSWORD}

# 桌面端默认 true：TUN 开着时，auto_detect_interface 负责把出站绑定到物理网卡，
# 否则 direct 出站会按默认路由又走回 tun（环），表现为「连上立刻被断」。
# 只有在 Windows 多网卡报 "not valid in its context" 时才关掉，并且要同时指定
# 网卡（客户端脚本支持 DEFAULT_INTERFACE=en0 之类）。
AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-true}
AI_MODE=${AI_MODE}
AI_SOCKS_SERVER=${AI_SOCKS_SERVER:-}
AI_SOCKS_PORT=${AI_SOCKS_PORT:-1080}
AI_SOCKS_USER=${AI_SOCKS_USER:-}
AI_SOCKS_PASS=${AI_SOCKS_PASS:-}
CLIENT_MIXED=${CLIENT_MIXED:-1}
ENV

  cat >"${CLIENT_ENV}" <<ENV
# ===== 客户端环境（单份渲染时用；多设备请在服务端用 device.sh 直接生成）=====
SERVER_IP=${SERVER_IP}
SERVER_HOST=${SERVER_HOST}
VLESS_PORT=${VLESS_PORT:-443}
REALITY_SERVER_NAME=${REALITY_DEST}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
UUID=${first_cred}

ENABLE_HY2=${ENABLE_HY2}
DOMAIN=${DOMAIN}
HY2_PORT=${HY2_PORT:-8443}
HY2_HOP_RANGE=${HY2_HOP_RANGE:-8443:8447}
HY2_PASSWORD=${first_cred}
OBFS_PASSWORD=${OBFS_PASSWORD}

# 桌面端默认 true：TUN 开着时，auto_detect_interface 负责把出站绑定到物理网卡，
# 否则 direct 出站会按默认路由又走回 tun（环），表现为「连上立刻被断」。
# 只有在 Windows 多网卡报 "not valid in its context" 时才关掉，并且要同时指定
# 网卡（客户端脚本支持 DEFAULT_INTERFACE=en0 之类）。
AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-true}
AI_MODE=${AI_MODE}
AI_SOCKS_SERVER=${AI_SOCKS_SERVER:-}
AI_SOCKS_PORT=${AI_SOCKS_PORT:-1080}
AI_SOCKS_USER=${AI_SOCKS_USER:-}
AI_SOCKS_PASS=${AI_SOCKS_PASS:-}
CLIENT_MIXED=${CLIENT_MIXED:-1}
ENV
  chmod 600 "${ENVFILE}" "${CLIENT_ENV}" "${DEVICES_LIST}"
  # root:root 在真实服务器上有效；某些环境（如容器）没这个组，失败也不影响 0600 权限
  chown root:root "${ENVFILE}" "${CLIENT_ENV}" 2>/dev/null || true

  log "已生成：${ENVFILE} / ${CLIENT_ENV} / ${DEVICES_LIST}"
  printf '\n  服务器 IP    %s\n  节点地址     %s%s\n  端口         %s/tcp\n  伪装站点     %s\n  设备数       %s\n  REALITY 公钥 %s\n  short_id     %s\n' \
    "${SERVER_IP}" "${SERVER_HOST}" "$([ "${SERVER_HOST}" = "${SERVER_IP}" ] && printf '（未配域名）' || printf '（域名）')" \
    "${VLESS_PORT:-443}" "${REALITY_DEST}" "$(device_rows | wc -l)" "${REALITY_PUBLIC_KEY}" "${SHORT_ID}"
}

secrets_uninstall() {
  if [[ "${PURGE:-0}" == "1" ]]; then
    rm -f "${ENVFILE}" "${CLIENT_ENV}" "${DEVICES_LIST}"
    log "已删除 deploy.env / client.env / devices.list"
  else
    log "保留 deploy.env / client.env / devices.list（如需删除：--purge）"
  fi
}
