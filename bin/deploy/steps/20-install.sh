# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 20：安装 sing-box（固定版本）
install_TITLE="安装 sing-box（固定版本 + systemd）"
install_OPTIONAL=0

install_check() {
  [[ -x "${SB_BIN}" ]] || return 1
  [[ -f /etc/systemd/system/sing-box.service ]] || return 1
  return 0
}

install_run() {
  local VER="${SING_BOX_VERSION:-1.14.3}" ARCH TMP BIN URL
  command -v curl >/dev/null 2>&1 || die "缺少 curl，先跑系统初始化"
  case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  mktemp_dir TMP

  if [[ -n "${SING_BOX_PKG:-}" ]]; then
    cp "${SING_BOX_PKG}" "${TMP}/sb.tar.gz"
  else
    URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
    log "下载 sing-box ${VER} (${ARCH})"
    curl -fL --retry 3 --connect-timeout 15 -o "${TMP}/sb.tar.gz" "${URL}" \
      || die "下载失败；可手动下载后用 SING_BOX_PKG= 指定本地包"
  fi
  tar -xzf "${TMP}/sb.tar.gz" -C "${TMP}"
  BIN="$(find "${TMP}" -type f -name sing-box -perm -u+x | head -1)"
  [[ -n "${BIN}" ]] || die "压缩包里找不到 sing-box"
  install -m 0755 "${BIN}" "${SB_BIN}"
  ensure_deploy_dir
  install -d -m 700 /var/lib/sing-box

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
  log "已安装：$("${SB_BIN}" version | head -1)"
}

install_uninstall() {
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload
  rm -f "${SB_BIN}"
  rm -rf /var/lib/sing-box
  log "已移除 sing-box 二进制与 systemd 单元"
}
