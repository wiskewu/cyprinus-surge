# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 50（可选）：Hysteria2 证书
hy2_TITLE="可选：Hysteria2 证书（ACME DNS-01）"
hy2_OPTIONAL=1

hy2_check() {
  [[ -s "${DEPLOY_DIR}/cert.pem" ]] && [[ -s "${DEPLOY_DIR}/key.pem" ]] || return 1
  grep -q '^ENABLE_HY2=1' "${ENVFILE}" 2>/dev/null || return 1
  return 0
}

hy2_run() {
  local ACME
  : "${DOMAIN:=}"
  : "${CF_TOKEN:=}"
  : "${ACME_EMAIL:=}"
  if [[ -z "${DOMAIN}" ]] || [[ -z "${CF_TOKEN}" ]] || [[ -z "${ACME_EMAIL}" ]]; then
    if [[ -n "${NONINTERACTIVE:-}" ]]; then
      warn "缺少 DOMAIN/CF_TOKEN/ACME_EMAIL，跳过 Hysteria2"
      return 0
    fi
    [[ -n "${DOMAIN}" ]]     || read -r -p "域名（例如 vps.example.com）: " DOMAIN
    [[ -n "${ACME_EMAIL}" ]] || read -r -p "邮箱（证书到期通知）: " ACME_EMAIL
    [[ -n "${CF_TOKEN}" ]]   || read -r -p "Cloudflare API Token: " CF_TOKEN
  fi
  [[ -n "${DOMAIN}" ]] && [[ -n "${ACME_EMAIL}" ]] && [[ -n "${CF_TOKEN}" ]] || die "DOMAIN / ACME_EMAIL / CF_TOKEN 不能为空"

  command -v acme.sh >/dev/null 2>&1 || {
    log "安装 acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL}" >/dev/null
  }
  ACME="${HOME}/.acme.sh/acme.sh"
  export CF_Token="${CF_TOKEN}"
  log "用 DNS-01 签发 ${DOMAIN}"
  "${ACME}" --issue --dns dns_cf -d "${DOMAIN}" --server letsencrypt --keylength ec-256 \
                                                                                        || warn "签发失败：确认 A 记录已生效（Cloudflare 需灰云）后重跑"
  "${ACME}" --install-cert -d "${DOMAIN}" --ecc \
    --fullchain-file "${DEPLOY_DIR}/cert.pem" \
    --key-file "${DEPLOY_DIR}/key.pem" \
    --reloadcmd "systemctl restart sing-box" || die "安装证书失败"
  chmod 600 "${DEPLOY_DIR}/cert.pem" "${DEPLOY_DIR}/key.pem"

  for f in "${ENVFILE}" "${CLIENT_ENV}"; do
    [[ -f "${f}" ]] || continue
    sed -i.bak "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|; s|^ENABLE_HY2=.*|ENABLE_HY2=1|" "${f}" && rm -f "${f}.bak"
  done
  log "证书就绪，ENABLE_HY2=1 已写入环境文件"
}

hy2_uninstall() {
  rm -f "${DEPLOY_DIR}/cert.pem" "${DEPLOY_DIR}/key.pem"
  for f in "${ENVFILE}" "${CLIENT_ENV}"; do
    [[ -f "${f}" ]] || continue
    sed -i.bak "s|^ENABLE_HY2=.*|ENABLE_HY2=0|" "${f}" && rm -f "${f}.bak"
  done
  log "已删除证书并把 ENABLE_HY2 置 0"
}
