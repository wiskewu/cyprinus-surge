#!/usr/bin/env bash
# ===========================================================================
# deploy.sh —— 一键脚本（自动生成，勿手改）
#   生成时间：2026-10-21T11:29:38Z
#   来源：lib.sh + steps/*.sh + onekey/driver.sh
#   重新生成：bash build-onekey.sh
# ===========================================================================
set -o pipefail
STEPS=(system install secrets server hy2 porthop)

# ---------------------------- lib.sh ----------------------------
# lib.sh —— 所有脚本共用的函数。不要单独运行，被 source。
#
# 注意：库不得修改调用方的 shell 选项。每个脚本在 source 之前自己声明
# set -euo pipefail / set -uo pipefail；这里再设一遍会把 -e（errexit）
# 强加给只想要 -u 的检查类脚本，导致某个管道返回非 0 时整个脚本静默退出。

DEPLOY_DIR="${DEPLOY_DIR:-/etc/sing-box}"
ENVFILE="${ENVFILE:-$DEPLOY_DIR/deploy.env}"
CLIENT_ENV="${CLIENT_ENV:-$DEPLOY_DIR/client.env}"
DEVICES_LIST="${DEVICES_LIST:-$DEPLOY_DIR/devices.list}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="$SELF_DIR/templates"

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
  [ "${SKIP_ROOT:-0}" = "1" ] && return 0
  [ "$(id -u)" = "0" ] || die "需要 root：sudo bash $0"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1，请先跑 00-bootstrap.sh"
}

# 读取 KEY=VALUE 环境文件（不执行其中的命令）
load_env() {
  local f="$1"
  [ -f "$f" ] || die "找不到 $f"
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

# 只替换模板里出现的 ${KEY}；值里的 & | \ 会被转义，跨 GNU/BSD sed 可用
render_vars() {
  local t="$1" o="$2" k v
  [ -f "$t" ] || die "模板不存在：$t"
  cp "$t" "$o"
  for k in $(grep -o '\${[A-Z_][A-Z0-9_]*}' "$t" | tr -d '${}' | sort -u); do
    v="${!k-}"
    [ -n "$v" ] || die "变量 $k 未设置（检查 ${ENVFILE}）"
    v="$(printf '%s' "$v" | sed -e 's/[&\\|]/\\&/g')"
    sed -i.bak "s|\${$k}|$v|g" "$o" && rm -f "$o.bak"
  done
}

# 把片段文件的原始内容塞进占位符（用 awk，避免 sed 转义地狱）
inject_block() {
  local f="$1" ph="$2" frag="$3"
  [ -f "$frag" ] || die "片段不存在：$frag"
  awk -v ph="$ph" -v frag="$frag" '
    index($0, ph) { while ((getline line < frag) > 0) print line; close(frag); next }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# 用逗号拼接多个 JSON 片段
join_json() {
  local out="" f
  for f in "$@"; do
    [ -n "$out" ] && out="$out,"$'\n'
    out="$out$(cat "$f")"
  done
  printf '%s' "$out"
}

json_valid() {
  command -v jq >/dev/null 2>&1 || return 0   # 没有 jq 就跳过，sing-box check 仍会报语法错
  jq -e . "$1" >/dev/null 2>&1 || die "JSON 语法错误：$1（用 jq . 看一眼）"
}

sb_check() {
  if [ -x "$SB_BIN" ]; then
    "$SB_BIN" check -c "$1" || die "sing-box 拒绝该配置：$1"
    log "配置校验通过：$1"
  else
    warn "未找到 ${SB_BIN}，跳过 sing-box check"
  fi
}

rand_pass() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-20}"; }

# ===== 设备名单 devices.list =====
# 格式：每行「名字 凭据 平台」，# 开头是注释。
# 一台设备一个凭据，同时当 VLESS 的 uuid 和 Hysteria2 的 password 用——
# 这样「吊销一台」就是删一行，两条入口同时失效，不会漏。
# 代价是同一个值出现在两个协议里（个人自用可接受，换来的是吊销的原子性）。
valid_device_name() { case "${1:-}" in "" | *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

device_rows() {
  [ -f "$DEVICES_LIST" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$DEVICES_LIST"
}

# device_get <名字> → 输出「凭据 平台」；不存在则返回 1
device_get() {
  local n c p
  while read -r n c p; do
    if [ "$n" = "$1" ]; then printf '%s %s\n' "$c" "${p:-desktop}"; return 0; fi
  done < <(device_rows)
  return 1
}

device_exists() { device_get "$1" >/dev/null 2>&1; }

# ---------------------------- 10-system.sh ----------------------------
# 步骤 10：系统初始化。函数与变量都以 system_ 前缀命名，便于一键脚本内联后不冲突。
system_TITLE="系统初始化（依赖 / BBR / swap / 时间同步 / SSH 加固 / 防火墙）"
system_OPTIONAL=0

system_check() {
  [ -f /etc/sysctl.d/99-proxy.conf ] || return 1
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | grep -q '^Status: active' || return 1
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] || return 1
  # 有可用公钥时，密码登录必须已经关掉；没有公钥则跳过不算未配置
  # （00-bootstrap 会提示先 ssh-copy-id，不该让 --status 一直报红）
  if ! sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; then
    system_has_authorized_key && return 1
  fi
  return 0
}

# 是否至少有一个可用的公钥：没有就不许关密码，否则会把人锁在门外
system_has_authorized_key() {
  local f
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -r "$f" ] || continue
    grep -qE '^[[:space:]]*ssh-(rsa|ed25519|ecdsa)' "$f" && return 0
  done
  return 1
}

# 探测 SSH 端口：当前连接 → sshd 监听 → sshd_config → 22
system_detect_ssh_ports() {
  local p=""
  [ -n "${SSH_CONNECTION:-}" ] && p="$(printf '%s' "$SSH_CONNECTION" | awk '{print $4}')"
  if command -v ss >/dev/null 2>&1; then
    p="$p $(ss -tlnpH 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u | paste -sd' ' -)"
  fi
  if [ -r /etc/ssh/sshd_config ]; then
    p="$p $(awk 'tolower($1)=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null | sort -u | paste -sd' ' -)"
  fi
  printf '%s\n' $p | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -
}

system_run() {
  local VLESS_PORT="${VLESS_PORT:-443}" HY2_PORT="${HY2_PORT:-8443}"
  local HY2_HOP_END="${HY2_HOP_END:-8447}" SWAP_MB="${SWAP_MB:-1024}" SSH_PORTS
  export DEBIAN_FRONTEND=noninteractive

  log "1/8 安装基础软件"
  apt-get update -qq
  apt-get -y -qq install --no-install-recommends \
    ca-certificates curl openssl jq tar unzip ufw fail2ban \
    unattended-upgrades vnstat mtr-tiny dnsutils >/dev/null

  log "2/8 内核参数：BBR + 大缓冲区"
  cat >/etc/sysctl.d/99-proxy.conf <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
SYSCTL
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr >/etc/modules-load.d/bbr.conf
  sysctl --system >/dev/null

  log "3/8 出站优先 IPv4"
  touch /etc/gai.conf
  grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf || echo 'precedence ::ffff:0:0/96  100' >>/etc/gai.conf

  log "4/8 swap"
  if ! swapon --show | grep -q .; then
    if [ ! -f /swapfile ]; then
      fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
      chmod 600 /swapfile && mkswap /swapfile >/dev/null
    fi
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
  fi

  log "5/8 时间同步"
  timedatectl set-timezone UTC
  timedatectl set-ntp true
  systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true

  # 先改 sshd 再收防火墙：万一配置写坏了，防火墙这一步根本不会执行到，
  # 你至少还留着一条能连回来的路（且已连着的会话不受影响）
  log "6/8 SSH 加固：仅公钥登录"
  if system_has_authorized_key; then
    mkdir -p /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/99-proxy.conf <<'SSHEOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
SSHEOF
    # Ubuntu 镜像自带 50-cloud-init.conf 里写着 PasswordAuthentication yes，
    # 而 sshd 对每个关键字取「第一个出现的值」，50 排在 99 前面 → 它赢。
    # 所以必须就地改掉，不能只在 99 里写一遍。
    CI=/etc/ssh/sshd_config.d/50-cloud-init.conf
    if [ -f "$CI" ] && grep -qE '^[[:space:]]*PasswordAuthentication' "$CI"; then
      [ -f "$CI.orig" ] || cp -a "$CI" "$CI.orig"
      sed -i 's/^[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/I' "$CI"
    fi
    if sshd -t 2>/dev/null; then
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
      if sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; then
        log "    已生效：passwordauthentication no"
      else
        warn "    未生效：/etc/ssh/sshd_config 里可能没有 Include sshd_config.d，请手工确认"
      fi
    else
      warn "sshd 配置有语法错，已回滚本步改动，sshd 未重启"
      rm -f /etc/ssh/sshd_config.d/99-proxy.conf
      [ -f "$CI.orig" ] && mv "$CI.orig" "$CI"
    fi
  else
    warn "没有找到任何 authorized_keys，跳过 SSH 加固：先 ssh-copy-id 装好公钥，再重跑本步"
  fi

  log "7/8 防火墙（绝不假设 SSH 是 22）"
  SSH_PORTS="$(printf '%s\n%s\n' "${SSH_PORT:-}" "$(system_detect_ssh_ports)" | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -)"
  [ -n "$SSH_PORTS" ] || SSH_PORTS=22
  log "    SSH 端口：${SSH_PORTS}"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for p in $SSH_PORTS; do ufw allow "${p}/tcp" comment 'ssh' >/dev/null; done
  ufw allow "${VLESS_PORT}/tcp" comment 'reality' >/dev/null
  ufw allow "${HY2_PORT}:${HY2_HOP_END}/udp" comment 'hysteria2' >/dev/null
  ufw --force enable >/dev/null

  log "8/8 目录与常驻服务"
  install -d -m 700 "$DEPLOY_DIR" /var/lib/sing-box /root/backups
  systemctl enable --now fail2ban vnstat >/dev/null 2>&1 || true
  log "完成：${SSH_PORTS} / ${VLESS_PORT}/tcp / ${HY2_PORT}-${HY2_HOP_END}/udp 已放行"
  warn "别忘了第二层防火墙：云厂商控制台的安全组也要放行同样的端口，否则表现为「部分端口通、部分超时」"
}

system_uninstall() {
  local VLESS_PORT="${VLESS_PORT:-443}" HY2_PORT="${HY2_PORT:-8443}" HY2_HOP_END="${HY2_HOP_END:-8447}"
  ufw delete allow "${VLESS_PORT}/tcp" >/dev/null 2>&1 || true
  ufw delete allow "${HY2_PORT}:${HY2_HOP_END}/udp" >/dev/null 2>&1 || true
  rm -f /etc/sysctl.d/99-proxy.conf
  rm -f /etc/ssh/sshd_config.d/99-proxy.conf
  [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf.orig ] && \
    mv /etc/ssh/sshd_config.d/50-cloud-init.conf.orig /etc/ssh/sshd_config.d/50-cloud-init.conf
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  log "已移除本项目加的 ufw 规则、sysctl 与 SSH 加固（SSH 规则、swap、ufw 开关保持不动）"
}

# ---------------------------- 20-install.sh ----------------------------
# 步骤 20：安装 sing-box（固定版本）
install_TITLE="安装 sing-box（固定版本 + systemd）"
install_OPTIONAL=0

install_check() {
  [ -x "$SB_BIN" ] || return 1
  [ -f /etc/systemd/system/sing-box.service ] || return 1
  return 0
}

install_run() {
  local VER="${SING_BOX_VERSION:-1.14.3}" ARCH TMP BIN URL
  command -v curl >/dev/null 2>&1 || die "缺少 curl，先跑系统初始化"
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' RETURN

  if [ -n "${SING_BOX_PKG:-}" ]; then
    cp "$SING_BOX_PKG" "$TMP/sb.tar.gz"
  else
    URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
    log "下载 sing-box ${VER} (${ARCH})"
    curl -fL --retry 3 --connect-timeout 15 -o "$TMP/sb.tar.gz" "$URL" \
      || die "下载失败；可手动下载后用 SING_BOX_PKG= 指定本地包"
  fi
  tar -xzf "$TMP/sb.tar.gz" -C "$TMP"
  BIN="$(find "$TMP" -type f -name sing-box -perm -u+x | head -1)"
  [ -n "$BIN" ] || die "压缩包里找不到 sing-box"
  install -m 0755 "$BIN" "$SB_BIN"
  install -d -m 700 "$DEPLOY_DIR" /var/lib/sing-box

  cat >/etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null
  log "已安装：$("$SB_BIN" version | head -1)"
}

install_uninstall() {
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload
  rm -f "$SB_BIN"
  rm -rf /var/lib/sing-box
  log "已移除 sing-box 二进制与 systemd 单元"
}

# ---------------------------- 30-secrets.sh ----------------------------
# 步骤 30：生成密钥与两份环境文件
secrets_TITLE="生成密钥（deploy.env / client.env / devices.list）"
secrets_OPTIONAL=0

secrets_check() {
  [ -s "$ENVFILE" ] && [ -s "$CLIENT_ENV" ] && [ -s "$DEVICES_LIST" ]
}

secrets_run() {
  local SERVER_IP="$SERVER_IP"
  mkdir -p "$DEPLOY_DIR"
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
    read -r -p "入口域名 DOMAIN [${DOMAIN:-留空}]（留空则客户端连公网 IP；启用 Hysteria2 时必填）: " _in; DOMAIN="${_in:-$DOMAIN}"
    if [ -n "$DOMAIN" ]; then
      read -r -p "启用 Hysteria2？[Y/n]: " _in
      case "${_in:-y}" in y|Y) ENABLE_HY2=1 ;; *) ENABLE_HY2=0 ;; esac
    else
      ENABLE_HY2=0
    fi
    read -r -p "第一台设备的名字 [main]: " _in; FIRST_DEVICE="${_in:-main}"
  else
    FIRST_DEVICE="${FIRST_DEVICE:-main}"
  fi
  valid_device_name "$FIRST_DEVICE" || die "设备名不合法：$FIRST_DEVICE（只允许字母数字 . _ -）"

  KP="$("$SB_BIN" generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$KP" | awk -F': *' '/PrivateKey/{print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$KP" | awk -F': *' '/PublicKey/{print $2}')"
  SHORT_ID="$(openssl rand -hex 4)"
  OBFS_PASSWORD="$(rand_pass 20)"
  [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "REALITY 密钥生成失败"

  # 设备名单已存在就原样保留：凭据不该因为重跑 secrets 而全变一遍。
  # 现有实例里的 devices.list 优先，Force 重跑也不覆盖。
  if [ ! -s "$DEVICES_LIST" ]; then
    umask 077
    cat >"$DEVICES_LIST" <<LIST
# ssh-sp 设备名单 —— 每行「名字 凭据 平台」，删一行 = 吊销那台设备（两条入口同时失效）
# 凭据同时当 VLESS 的 uuid 和 Hysteria2 的 password 用，保证吊销是原子的
$FIRST_DEVICE $("$SB_BIN" generate uuid) desktop
LIST
    chmod 600 "$DEVICES_LIST"
    log "已创建设备名单：$DEVICES_LIST（第一台：$FIRST_DEVICE）"
  else
    log "设备名单已存在，保留：$DEVICES_LIST"
  fi

  # client.env 里的 UUID / HY2_PASSWORD 是 devices.list 首行的镜像，
  # 让「在客户端机器上手动渲染单份」的老用法继续可用；日常以 devices.list 为准。
  local first_cred first_plat
  first_cred="$(device_get "$FIRST_DEVICE" 2>/dev/null | awk '{print $1}')" \
    || first_cred="$(device_rows | head -1 | awk '{print $2}')"
  [ -n "$first_cred" ] || die "设备名单读不出凭据：$DEVICES_LIST"
  first_plat="$(device_get "$FIRST_DEVICE" 2>/dev/null | awk '{print $2}')" || first_plat=desktop

  # 节点地址：域名优先，留空就用公网 IP
  SERVER_HOST="$DOMAIN"
  [ -n "$SERVER_HOST" ] || SERVER_HOST="$SERVER_IP"

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

AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-false}
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

AUTO_DETECT_INTERFACE=${AUTO_DETECT_INTERFACE:-false}
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
  if [ "${PURGE:-0}" = "1" ]; then
    rm -f "$ENVFILE" "$CLIENT_ENV" "$DEVICES_LIST"
    log "已删除 deploy.env / client.env / devices.list"
  else
    log "保留 deploy.env / client.env / devices.list（如需删除：--purge）"
  fi
}

# ---------------------------- 40-server.sh ----------------------------
# 步骤 40：渲染服务端配置并启动
server_TITLE="渲染服务端配置并启动（双入口）"
server_OPTIONAL=0

server_check() {
  [ -s "$DEPLOY_DIR/config.json" ] || return 1
  systemctl is-active --quiet sing-box 2>/dev/null || return 1
  return 0
}

# 把设备名单渲染成 sing-box 的 users 数组内容（逗号分隔，不含外层方括号）。
# 模板里写 "users": [ __USERS__ ]，方括号由模板负责。
# $1=名单内容 $2=凭据字段名(uuid|password) $3=输出文件
render_users() {
  local rows="$1" field="$2" out="$3" n c p first=1
  : >"$out"
  while read -r n c p; do
    [ -n "$first" ] || printf ',\n' >>"$out"
    if [ "$field" = uuid ]; then
      printf '        { "name": "%s", "uuid": "%s", "flow": "xtls-rprx-vision" }' "$n" "$c" >>"$out"
    else
      printf '        { "name": "%s", "password": "%s" }' "$n" "$c" >>"$out"
    fi
    first=""
  done <<<"$rows"
  [ -n "$first" ] && die "设备名单解析不出条目：$DEVICES_LIST"
  return 0
}

server_run() {
  local T
  load_env "$ENVFILE"
  export CERT_DIR="${CERT_DIR:-$DEPLOY_DIR}"
  [ -x "$SB_BIN" ] || die "sing-box 未安装"
  T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN

  # users 数组按设备名单渲染：一份设备名单 = 一组凭据，删一行就吊销那台
  local rows; rows="$(device_rows)"
  [ -n "$rows" ] || die "设备名单为空：$DEVICES_LIST"

  render_vars "$TPL_DIR/in-reality.json.tmpl" "$T/in1.json"
  render_users "$rows" uuid "$T/u1.json"
  inject_block "$T/in1.json" "__USERS__" "$T/u1.json"
  cp "$T/in1.json" "$T/inbounds.json"
  if [ "${ENABLE_HY2:-0}" = "1" ]; then
    for f in cert.pem key.pem; do
      [ -s "$DEPLOY_DIR/$f" ] || die "缺少 $DEPLOY_DIR/$f：先跑 Hysteria2 步骤，或把 ENABLE_HY2 改成 0"
    done
    render_vars "$TPL_DIR/in-hy2.json.tmpl" "$T/in2.json"
    render_users "$rows" password "$T/u2.json"
    inject_block "$T/in2.json" "__USERS__" "$T/u2.json"
    join_json "$T/in1.json" "$T/in2.json" >"$T/inbounds.json"
    log "双入口：REALITY:${VLESS_PORT} + Hysteria2:${HY2_PORT}/udp（$(printf '%s\n' "$rows" | wc -l) 台设备）"
  else
    log "单入口：REALITY:${VLESS_PORT}（$(printf '%s\n' "$rows" | wc -l) 台设备）"
  fi

  render_vars "$TPL_DIR/server.json.tmpl" "$T/server.json"
  inject_block "$T/server.json" "__INBOUNDS__" "$T/inbounds.json"
  json_valid "$T/server.json"
  sb_check "$T/server.json"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    # 预览也走 data/：脚本目录是入库的，往里写会把服务端配置（含 REALITY 私钥）带进版本控制
    local out="${OUT:-data/config.preview.json}"
    mkdir -p "$(dirname "$out")"
    cp "$T/server.json" "$out"
    log "DRY_RUN：已生成 $out"
    return 0
  fi
  install -m 600 "$T/server.json" "$DEPLOY_DIR/config.json"
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 30 --no-pager; die "sing-box 没起来"; }
  log "服务已启动"
}

server_uninstall() {
  systemctl stop sing-box >/dev/null 2>&1 || true
  rm -f "$DEPLOY_DIR/config.json"
  log "已停止服务并删除 config.json（密钥与证书保留）"
}

# ---------------------------- 50-hy2.sh ----------------------------
# 步骤 50（可选）：Hysteria2 证书
hy2_TITLE="可选：Hysteria2 证书（ACME DNS-01）"
hy2_OPTIONAL=1

hy2_check() {
  [ -s "$DEPLOY_DIR/cert.pem" ] && [ -s "$DEPLOY_DIR/key.pem" ] || return 1
  grep -q '^ENABLE_HY2=1' "$ENVFILE" 2>/dev/null || return 1
  return 0
}

hy2_run() {
  local ACME
  : "${DOMAIN:=}"
  : "${CF_TOKEN:=}"
  : "${ACME_EMAIL:=}"
  if [ -z "$DOMAIN" ] || [ -z "$CF_TOKEN" ] || [ -z "$ACME_EMAIL" ]; then
    if [ -n "${NONINTERACTIVE:-}" ]; then
      warn "缺少 DOMAIN/CF_TOKEN/ACME_EMAIL，跳过 Hysteria2"
      return 0
    fi
    [ -n "$DOMAIN" ]     || read -r -p "域名（例如 vps.example.com）: " DOMAIN
    [ -n "$ACME_EMAIL" ] || read -r -p "邮箱（证书到期通知）: " ACME_EMAIL
    [ -n "$CF_TOKEN" ]   || read -r -p "Cloudflare API Token: " CF_TOKEN
  fi
  [ -n "$DOMAIN" ] && [ -n "$ACME_EMAIL" ] && [ -n "$CF_TOKEN" ] || die "DOMAIN / ACME_EMAIL / CF_TOKEN 不能为空"

  command -v acme.sh >/dev/null 2>&1 || {
    log "安装 acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL" >/dev/null
  }
  ACME="$HOME/.acme.sh/acme.sh"
  export CF_Token="$CF_TOKEN"
  log "用 DNS-01 签发 $DOMAIN"
  "$ACME" --issue --dns dns_cf -d "$DOMAIN" --server letsencrypt --keylength ec-256 || \
    warn "签发失败：确认 A 记录已生效（Cloudflare 需灰云）后重跑"
  "$ACME" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$DEPLOY_DIR/cert.pem" \
    --key-file "$DEPLOY_DIR/key.pem" \
    --reloadcmd "systemctl restart sing-box" || die "安装证书失败"
  chmod 600 "$DEPLOY_DIR/cert.pem" "$DEPLOY_DIR/key.pem"

  for f in "$ENVFILE" "$CLIENT_ENV"; do
    [ -f "$f" ] || continue
    sed -i.bak "s|^DOMAIN=.*|DOMAIN=$DOMAIN|; s|^ENABLE_HY2=.*|ENABLE_HY2=1|" "$f" && rm -f "$f.bak"
  done
  log "证书就绪，ENABLE_HY2=1 已写入环境文件"
}

hy2_uninstall() {
  rm -f "$DEPLOY_DIR/cert.pem" "$DEPLOY_DIR/key.pem"
  for f in "$ENVFILE" "$CLIENT_ENV"; do
    [ -f "$f" ] || continue
    sed -i.bak "s|^ENABLE_HY2=.*|ENABLE_HY2=0|" "$f" && rm -f "$f.bak"
  done
  log "已删除证书并把 ENABLE_HY2 置 0"
}

# ---------------------------- 60-porthop.sh ----------------------------
# 步骤 60（可选）：Hysteria2 端口跳跃
porthop_TITLE="可选：Hysteria2 端口跳跃（iptables 重定向）"
porthop_OPTIONAL=1

porthop_rule_args() {
  PORTHOP_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  PORTHOP_START="${HY2_PORT:-8443}"
  PORTHOP_END="${HY2_HOP_RANGE##*:}"
  [ -n "$PORTHOP_IFACE" ] || return 1
  return 0
}

porthop_check() {
  command -v iptables >/dev/null 2>&1 || return 1
  porthop_rule_args || return 1
  iptables -t nat -C PREROUTING -i "$PORTHOP_IFACE" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "$PORTHOP_START" 2>/dev/null
}

porthop_run() {
  load_env "$ENVFILE" 2>/dev/null || true
  [ "${ENABLE_HY2:-0}" = "1" ] || { warn "ENABLE_HY2=0，跳过端口跳跃"; return 0; }
  porthop_rule_args || die "识别不到默认网卡"
  if iptables -t nat -C PREROUTING -i "$PORTHOP_IFACE" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "$PORTHOP_START" 2>/dev/null; then
    log "规则已存在"
  else
    iptables -t nat -A PREROUTING -i "$PORTHOP_IFACE" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "$PORTHOP_START"
    log "已添加：udp ${PORTHOP_START}:${PORTHOP_END} → ${PORTHOP_START}（$PORTHOP_IFACE）"
  fi
  export DEBIAN_FRONTEND=noninteractive
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
  apt-get -y -qq install iptables-persistent >/dev/null
  netfilter-persistent save >/dev/null
  log "已持久化"
}

porthop_uninstall() {
  porthop_rule_args || return 0
  iptables -t nat -D PREROUTING -i "$PORTHOP_IFACE" -p udp --dport "${PORTHOP_START}:${PORTHOP_END}" -j REDIRECT --to-ports "$PORTHOP_START" 2>/dev/null || true
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  log "已移除端口跳跃规则"
}

# ============================================================================
# 驱动：由 build-onekey.sh 拼接到 deploy.sh 末尾。不要单独执行本文件。
# ============================================================================
OPT_REUSE=0; OPT_OVERWRITE=0; OPT_YES=0; OPT_DRY=0
OPT_UNINSTALL=0; OPT_PURGE=0; OPT_REINSTALL=0
ONLY=""; SKIP=""; INTERACTIVE=1
PURGE=0

usage() {
  cat <<'USAGE'
用法：sudo bash deploy.sh [选项]

不带选项 → 交互模式：先扫描每一步的状态，再逐个询问「复用 / 覆盖 / 跳过」。

  --reuse            已配置的步骤直接复用（不提问）
  --overwrite        已配置的步骤重新执行并覆盖
  --only a,b         只跑指定步骤（system,install,secrets,server,hy2,porthop）
  --skip a,b         跳过指定步骤
  --yes              全部确认，不再提问
  --dry-run          只打印计划，不执行
  --status           只看状态
  --uninstall        卸载（保留 deploy.env / 证书）
  --purge            卸载并删除 deploy.env / 证书
  --reinstall        卸载并重装（等价 --purge 后全量 --overwrite）
  -h, --help         显示本帮助

环境变量（也可直接传给脚本）：
  SSH_PORT  REALITY_DEST  DOMAIN  ENABLE_HY2  SING_BOX_VERSION
  CF_TOKEN  ACME_EMAIL  SERVER_IP  AUTO_DETECT_INTERFACE
USAGE
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --reuse) OPT_REUSE=1 ;;
      --overwrite) OPT_OVERWRITE=1 ;;
      --yes) OPT_YES=1; INTERACTIVE=0 ;;
      --dry-run) OPT_DRY=1 ;;
      --uninstall) OPT_UNINSTALL=1 ;;
      --purge) OPT_PURGE=1; PURGE=1 ;;
      --reinstall) OPT_REINSTALL=1; OPT_PURGE=1; PURGE=1 ;;
      --status) OPT_DRY=1; OPT_YES=1 ;;
      --only) shift; ONLY="${1:-}" ;;
      --only=*) ONLY="${1#*=}" ;;
      --skip) shift; SKIP="${1:-}" ;;
      --skip=*) SKIP="${1#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（--help 看用法）" ;;
    esac
    shift
  done
}

hy2_enabled() { [ "${ENABLE_HY2:-0}" = "1" ] || grep -q '^ENABLE_HY2=1' "$ENVFILE" 2>/dev/null; }

step_title() { local v="${1}_TITLE"; printf '%s' "${!v:-$1}"; }
step_optional() { local v="${1}_OPTIONAL"; printf '%s' "${!v:-0}"; }
step_state() { if "${1}_check" >/dev/null 2>&1; then echo "已配置"; else echo "未配置"; fi; }

selected() {
  local id="$1"
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$id,"*) ;; *) return 1 ;; esac; fi
  if [ -n "$SKIP" ]; then case ",$SKIP," in *",$id,"*) return 1 ;; esac; fi
  return 0
}

print_plan() {
  printf '\n%-10s %-8s %-6s %s\n' "步骤" "状态" "可选" "说明"
  printf '%s\n' "--------------------------------------------------------------"
  local id
  for id in "${STEPS[@]}"; do
    selected "$id" || { printf '%-10s %-8s %-6s %s（按参数排除）\n' "$id" "-" "-" "$(step_title "$id")"; continue; }
    printf '%-10s %-8s %-6s %s\n' "$id" "$(step_state "$id")" "$([ "$(step_optional "$id")" = 1 ] && echo yes || echo no)" "$(step_title "$id")"
  done
  printf '%s\n\n' "--------------------------------------------------------------"
}

# 返回码：0=覆盖重跑，1=复用，2=跳过
decide() {
  local id="$1" a
  [ "$OPT_OVERWRITE" = 1 ] && return 0
  [ "$OPT_REUSE" = 1 ] && return 1
  [ "$INTERACTIVE" = 0 ] && return 1
  printf '  [%s] 已配置（%s）\n      (r) 复用已存在配置  (o) 覆盖重跑  (s) 跳过   [r] ' "$id" "$(step_title "$id")"
  read -r a
  case "${a:-r}" in
    r|R) return 1 ;;
    o|O) return 0 ;;
    *)   return 2 ;;
  esac
}

execute() {
  local id="$1"
  log "===== ${id}：$(step_title "$id") ====="
  if [ "$OPT_DRY" = 1 ]; then
    log "DRY_RUN：跳过执行"
    return 0
  fi
  # 子 shell + errexit：单步失败不会带崩整个流程
  ( set -eo pipefail; "${id}_run" )
}

do_install() {
  local id rc run_ok=0 run_fail=0
  local -a todo=()
  for id in "${STEPS[@]}"; do
    selected "$id" || continue
    if [ "$(step_optional "$id")" = 1 ] && ! hy2_enabled && { [ "$id" = "hy2" ] || [ "$id" = "porthop" ]; }; then
      log "跳过 $id（ENABLE_HY2 未开启）"
      continue
    fi
    if [ "$(step_state "$id")" = "已配置" ]; then
      decide "$id"; rc=$?
      case "$rc" in
        1) log "复用 $id（不执行）"; continue ;;
        2) log "跳过 $id"; continue ;;
      esac
    fi
    todo+=("$id")
  done

  if [ "${#todo[@]}" -eq 0 ]; then
    log "没有需要执行的步骤"
    return 0
  fi
  log "将执行：${todo[*]}"
  if [ "$INTERACTIVE" = 1 ] && [ "$OPT_DRY" = 0 ]; then
    printf '确认开始？[Y/n] '
    local a; read -r a
    case "${a:-y}" in y|Y) ;; *) log "已取消"; exit 1 ;; esac
  fi
  for id in "${todo[@]}"; do
    if execute "$id"; then run_ok=$((run_ok+1)); else
      run_fail=$((run_fail+1))
      warn "步骤 $id 失败"
      if [ "$INTERACTIVE" = 1 ]; then
        printf '继续后面的步骤？[y/N] '
        local a; read -r a
        case "${a:-n}" in y|Y) ;; *) die "中止：$id 失败" ;; esac
      else
        die "中止：$id 失败"
      fi
    fi
  done
  printf '\n完成：%d 个步骤成功，%d 个失败\n' "$run_ok" "$run_fail"
  [ "$run_fail" -eq 0 ] || exit 1
}

do_uninstall() {
  local id
  load_env "$ENVFILE" 2>/dev/null || true
  if [ "$OPT_DRY" = 1 ]; then
    log "DRY_RUN：将卸载 ${STEPS[*]}"
    return 0
  fi
  if [ "$INTERACTIVE" = 1 ] && [ "$OPT_YES" = 0 ]; then
    printf '\n将卸载以下内容：\n  - sing-box 服务与二进制、systemd 单元\n  - ufw 里本项目加的 443/8443-8447 规则、sysctl 优化\n'
    [ "$PURGE" = 1 ] && printf '  - deploy.env / client.env / 证书（--purge）\n'
    printf '确认？[y/N] '
    local a; read -r a
    case "${a:-n}" in y|Y) ;; *) log "已取消"; return 0 ;; esac
  fi
  for ((i=${#STEPS[@]}-1; i>=0; i--)); do
    id="${STEPS[i]}"
    if "${id}_check" >/dev/null 2>&1; then
      log "卸载 $id"
      ( set -eo pipefail; "${id}_uninstall" ) || warn "$id 卸载不完整（可手工检查）"
    fi
  done
  if [ "$PURGE" = 1 ]; then
    rm -rf "$DEPLOY_DIR"
    log "已删除 $DEPLOY_DIR"
    rmdir /root/deploy 2>/dev/null || true
  else
    log "保留 $DEPLOY_DIR（含密钥与证书，便于下次复用）"
  fi
  log "卸载结束。SSH 防火墙规则、swap、ufw 开关均未改动。"
}

main() {
  parse_args "$@"
  local _d="${DOMAIN:-}" _h="${ENABLE_HY2:-}" _r="${REALITY_DEST:-}" _s="${SERVER_IP:-}"
  [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true
  [ -n "$_d" ] && DOMAIN="$_d"
  [ -n "$_h" ] && ENABLE_HY2="$_h"
  [ -n "$_r" ] && REALITY_DEST="$_r"
  [ -n "$_s" ] && SERVER_IP="$_s"

  if [ "$OPT_REINSTALL" = 1 ]; then
    OPT_UNINSTALL=1
    do_uninstall
    OPT_UNINSTALL=0; OPT_OVERWRITE=1; OPT_REUSE=0
    log "重新安装：全量覆盖"
  fi

  if [ "$OPT_UNINSTALL" = 1 ]; then
    do_uninstall
    return 0
  fi

  if [ "$OPT_DRY" = 1 ]; then
    print_plan
    [ "$OPT_YES" = 1 ] && [ "${OPT_PLAN_ONLY:-0}" = "1" ] && return 0
  else
    print_plan
  fi

  [ "$OPT_DRY" = 1 ] || need_root
  if [ ! -f /etc/debian_version ]; then
    warn "本脚本只在 Debian / Ubuntu 上验证过，当前系统可能不兼容"
  fi

  [ -n "${ENABLE_HY2:-}" ] || ENABLE_HY2=0
  do_install
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
