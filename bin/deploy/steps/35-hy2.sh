# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# 步骤 35（可选）：Hysteria2 证书
#
# 排在 server 之前：渲染服务端配置时要读 cert.pem / key.pem，缺证书就得停下来。
# 排在 secrets 之后：域名与 ENABLE_HY2 由 secrets 写进 deploy.env，本步骤自己再读一次。
hy2_TITLE="可选：Hysteria2 证书（ACME DNS-01）"
hy2_OPTIONAL=1

hy2_check() {
  [[ -s "${DEPLOY_DIR}/cert.pem" ]] && [[ -s "${DEPLOY_DIR}/key.pem" ]] || return 1
  grep -q '^ENABLE_HY2=1' "${ENVFILE}" 2>/dev/null || return 1
  return 0
}

hy2_run() {
  local ACME _dom="${DOMAIN:-}" _hy2="${ENABLE_HY2:-}"
  # 驱动是先攒计划再执行，本轮 secrets 刚写进 deploy.env 的 DOMAIN / ENABLE_HY2
  # 传不进这个子 shell，必须自己读一遍，否则会在发证时再问一次域名。
  # 命令行显式给的值优先，与驱动启动时的覆盖规则一致。
  load_env_optional "${ENVFILE}" || true
  [[ -n "${_dom}" ]] && DOMAIN="${_dom}"
  [[ -n "${_hy2}" ]] && ENABLE_HY2="${_hy2}"
  # 与 port-hop 一致：没启用就直接跳过，不要往下走到交互提问
  if [[ "${ENABLE_HY2:-0}" != "1" ]]; then
    warn "ENABLE_HY2=0，跳过 Hysteria2"
    return 0
  fi
  : "${DOMAIN:=}"
  : "${CF_TOKEN:=}"
  : "${ACME_EMAIL:=}"
  if [[ -z "${DOMAIN}" ]] || [[ -z "${CF_TOKEN}" ]] || [[ -z "${ACME_EMAIL}" ]]; then
    if [[ -n "${NONINTERACTIVE:-}" ]]; then
      warn "缺少 DOMAIN/CF_TOKEN/ACME_EMAIL，跳过 Hysteria2"
      return 0
    fi
    # 没有终端就只能报错：直接 read 会因 stdin 已关闭而静默失败在 set -e 下
    if [[ ! -t 0 ]]; then
      die "缺少 DOMAIN/CF_TOKEN/ACME_EMAIL，且当前不是交互终端；补齐后重跑或用 NONINTERACTIVE=1 跳过"
    fi
    [[ -n "${DOMAIN}" ]] || read -r -p "域名（例如 vps.example.com）: " DOMAIN
    [[ -n "${ACME_EMAIL}" ]] || read -r -p "邮箱（证书到期通知）: " ACME_EMAIL
    [[ -n "${CF_TOKEN}" ]] || read -r -p "Cloudflare API Token: " CF_TOKEN
  fi
  [[ -n "${DOMAIN}" ]] && [[ -n "${ACME_EMAIL}" ]] && [[ -n "${CF_TOKEN}" ]] || die "DOMAIN / ACME_EMAIL / CF_TOKEN 不能为空"

  ensure_deploy_dir
  command -v acme.sh >/dev/null 2>&1 || {
    log "安装 acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL}" >/dev/null
  }
  ACME="${HOME}/.acme.sh/acme.sh"
  export CF_Token="${CF_TOKEN}"
  log "用 DNS-01 签发 ${DOMAIN}"
  # acme.sh 在「域名未变、还没到续期时间」时会打印 Domains not changed / Skipping
  # 并返回非 0。那不是失败，后面照常把已有证书装到 ${DEPLOY_DIR}。
  local issue_log issue_rc=0 T
  mktemp_dir T
  issue_log="${T}/acme-issue.log"
  "${ACME}" --issue --dns dns_cf -d "${DOMAIN}" --server letsencrypt --keylength ec-256 \
    >"${issue_log}" 2>&1 || issue_rc=$?
  cat "${issue_log}" 2>/dev/null || true
  if [[ "${issue_rc}" -eq 0 ]]; then
    log "签发完成"
  elif grep -qE 'Domains not changed|Skip' "${issue_log}" 2>/dev/null; then
    log "证书仍在有效期，跳过签发"
  else
    warn "签发失败：确认 A 记录已生效（Cloudflare 需灰云）后重跑"
    warn "    继续尝试安装 acme.sh 里已有的证书"
  fi
  # reloadcmd 用 try-restart：本步骤现在跑在 server 之前，此时还没有 config.json，
  # 直接 restart 会失败并被 acme.sh 当成「证书安装失败」。续期时服务在跑，照常重启。
  "${ACME}" --install-cert -d "${DOMAIN}" --ecc \
    --fullchain-file "${DEPLOY_DIR}/cert.pem" \
    --key-file "${DEPLOY_DIR}/key.pem" \
    --reloadcmd "systemctl try-restart sing-box 2>/dev/null || true" || die "安装证书失败"
  # acme.sh 直接写目标路径，权限是 600 root:root。降权运行时 sing-box 读不到，
  # 这里补一次组读，规则与 install_service_file 一致。
  svc_user="$(systemctl show -p User --value sing-box 2>/dev/null || true)"
  chmod 600 "${DEPLOY_DIR}/cert.pem" "${DEPLOY_DIR}/key.pem"
  if [[ -n "${svc_user}" && "${svc_user}" != "root" ]] && group="$(id -gn "${svc_user}" 2>/dev/null)"; then
    chgrp "${group}" "${DEPLOY_DIR}/cert.pem" "${DEPLOY_DIR}/key.pem" 2>/dev/null || true
    chmod 640 "${DEPLOY_DIR}/cert.pem" "${DEPLOY_DIR}/key.pem" 2>/dev/null || true
  fi

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
