#!/usr/bin/env bash
# bin/deploy/ops/monitor.sh —— 服务端观测：定时探针（端口 / 出口 IP / AI 可达 / 丢包延迟）。
#   探针记四件事：服务与端口、服务器出口 IP、AI 站点可达性、到 1.1.1.1 的丢包与延迟。
#   结果按 CSV 追加到 /var/lib/sing-box-monitor/probe.log，定时器每 5 分钟跑一次。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"

STATE_DIR="${STATE_DIR:-/var/lib/sing-box-monitor}"
PROBE_LOG="${STATE_DIR}/probe.log"
PROBE_KEEP="${PROBE_KEEP:-5000}"
SERVICE_UNIT="/etc/systemd/system/sing-box-probe.service"
TIMER_UNIT="/etc/systemd/system/sing-box-probe.timer"

MODE=setup

usage() {
  cat <<'EOF'
用法：sudo bash bin/deploy/ops/monitor.sh [选项]

  （不带选项）        安装：装 5 分钟探针定时器并立刻跑一次
  --probe             走一次探针并评估告警
  --alert-check       只评估告警
  --alert-test        发一条测试告警
  --status            看最近 20 条探针与当前端口状态
  --uninstall         停并删探针定时器
  -h, --help          显示帮助

探针每次记四项：服务与端口、服务器出口 IP、AI 站点可达性、到 1.1.1.1 的丢包与延迟。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe) MODE=probe ;;
    --alert-check) MODE=alertcheck ;;
    --alert-test) MODE=alerttest ;;
    --status) MODE=status ;;
    --uninstall) MODE=uninstall ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "未知参数：$1"
      ;;
  esac
  shift
done

# deploy.env 可有可无：有就读端口与开关。注意 die 是 exit，不能靠 || true 兜住
[[ -f "${ENVFILE}" ]] && load_env "${ENVFILE}"
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-8443}"
ENABLE_HY2="${ENABLE_HY2:-0}"

env_set() { # $1=键 $2=值，写回 deploy.env（缺行就追加）
  [[ -f "${ENVFILE}" ]] || die "缺少 ${ENVFILE}，先跑 bin/deploy/one/secrets.sh"
  if grep -q "^$1=" "${ENVFILE}"; then
    sed -i "s|^$1=.*|$1=$2|" "${ENVFILE}"
  else
    printf '%s=%s\n' "$1" "$2" >>"${ENVFILE}"
  fi
}

port_listening() { # $1=tcp|udp $2=端口
  if [[ "$1" == tcp ]]; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  else
    ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
  fi
}

# ---------------------------------------------------------------- 探针
rtt_of() { # 从 ping 输出里取 "丢包率 平均延迟"
  local out loss avg
  out="$(ping -c 3 -W 2 1.1.1.1 2>/dev/null || true)"
  loss="$(printf '%s' "${out}" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+' || true)"
  avg="$(printf '%s' "${out}" | awk -F'/' '/rtt|round-trip/ {print $5}' || true)"
  printf '%s %s\n' "${loss:--}" "${avg:--}"
}

# AI 出口判定：用 Cloudflare trace 拿状态码与机房。
# 403/429 表示「连上了但被拦」，可访问性仍然存在；拿不到任何响应才算不可达。
ai_of() { # 输出 "状态码 loc 可达性"
  local out code loc rc reach
  out="$(curl -sS -m 10 -w '\n%{http_code}' https://chatgpt.com/cdn-cgi/trace 2>/dev/null)"
  rc=$?
  code="$(printf '%s' "${out}" | tail -n1)"
  loc="$(printf '%s' "${out}" | awk -F= '$1=="loc"{print $2}')"
  case "${code}" in
    2?? | 4??) reach=ok ;;
    *) reach=fail ;;
  esac
  # curl 非零说明 TCP 或 TLS 就没走通
  [[ "${rc}" == 0 ]] || reach=fail
  printf '%s %s %s\n' "${code:--}" "${loc:--}" "${reach}"
}

probe_once() {
  local ts svc tcp udp ip ai_code ai_loc ai_reach loss avg
  ts="$(date -u +%FT%TZ)"
  svc="$(systemctl is-active sing-box 2>/dev/null || printf 'down')"
  port_listening tcp "${VLESS_PORT}" && tcp=up || tcp=down
  if [[ "${ENABLE_HY2}" == "1" ]]; then
    port_listening udp "${HY2_PORT}" && udp=up || udp=down
  else
    udp="n/a"
  fi
  ip="$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || printf '-')"
  read -r ai_code ai_loc ai_reach <<<"$(ai_of)"
  read -r loss avg <<<"$(rtt_of)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${ts}" "${svc}" "${tcp}" "${udp}" "${ip}" "${ai_code}" "${ai_loc}" "${ai_reach}" "${loss}" "${avg}"
}

log_is_writable() { mkdir -p "${STATE_DIR}" && chmod 750 "${STATE_DIR}"; }

trim_log() {
  [[ -f "${PROBE_LOG}" ]] || return 0
  local n
  n="$(wc -l <"${PROBE_LOG}" | tr -d ' ')"
  [[ "${n}" -gt "${PROBE_KEEP}" ]] || return 0
  tail -n "${PROBE_KEEP}" "${PROBE_LOG}" >"${PROBE_LOG}.tmp" && mv "${PROBE_LOG}.tmp" "${PROBE_LOG}"
}

run_probe() {
  need_root
  log_is_writable
  [[ -f "${PROBE_LOG}" ]] || printf 'ts,service,tcp,udp,egress,ai_code,ai_loc,ai_reach,loss_pct,rtt_avg_ms\n' >"${PROBE_LOG}"
  probe_once >>"${PROBE_LOG}"
  trim_log
  alert_check || true
}

# ---------------------------------------------------------------- 定时器
install_timer() {
  need_root
  cat >"${SERVICE_UNIT}" <<EOF
[Unit]
Description=sing-box probe (port / egress / AI / rtt)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SELF_DIR}/monitor.sh --probe
Nice=10
EOF
  cat >"${TIMER_UNIT}" <<'EOF'
[Unit]
Description=sing-box probe timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box-probe.timer >/dev/null 2>&1
  log "探针定时器已启用：每 5 分钟一次，记录在 ${PROBE_LOG}"
}

remove_timer() {
  systemctl disable --now sing-box-probe.timer >/dev/null 2>&1 || true
  rm -f "${SERVICE_UNIT}" "${TIMER_UNIT}"
  systemctl daemon-reload
  log "探针定时器已移除（记录保留）"
}

# ---------------------------------------------------------------- 告警
# 阈值都可用环境变量覆盖；推送支持 Telegram 与通用 webhook，都没有则只写日志。
ALERT_STATE="${STATE_DIR}/alert.state"

# 推送：多个通道可以同时配，任一成功即算送达。
# 大陆可直连的选项：企业微信/钉钉群机器人、Server酱、SMTP 邮件；
# Telegram 需要代理，服务器上通常不可达，保留但不建议作为主通道。
alert_send() { # $1=正文
  local text="$1" resp ok=0 title
  title="$(hostname) 告警"
  if [[ -n "${ALERT_WECOM_WEBHOOK:-}" ]]; then
    if resp="$(jq -n --arg t "${text}" '{msgtype: "text", text: {content: $t}}' \
      | curl -fsS -m 10 -H 'Content-Type: application/json' --data-binary @- "${ALERT_WECOM_WEBHOOK}" 2>&1)"; then
      ok=1
    else
      warn "企业微信推送失败：${resp}"
    fi
  fi
  if [[ -n "${ALERT_SERVERCHAN_KEY:-}" ]]; then
    if resp="$(curl -fsS -m 10 --data-urlencode "title=${title}" --data-urlencode "desp=${text}" \
      "https://sctapi.ftqq.com/${ALERT_SERVERCHAN_KEY}.send" 2>&1)"; then
      ok=1
    else
      warn "Server酱推送失败：${resp}"
    fi
  fi
  if [[ -n "${ALERT_SMTP_URL:-}" && -n "${ALERT_MAIL_TO:-}" ]]; then
    if resp="$(printf 'From: %s\nTo: %s\nSubject: %s\n\n%s\n' \
      "${ALERT_SMTP_USER:-alert@localhost}" "${ALERT_MAIL_TO}" "${title}" "${text}" \
      | curl -fsS -m 15 "${ALERT_SMTP_URL}" --mail-from "${ALERT_SMTP_USER:-alert@localhost}" \
        --mail-rcpt "${ALERT_MAIL_TO}" --user "${ALERT_SMTP_USER:-}:${ALERT_SMTP_PASS:-}" \
        --upload-file - 2>&1)"; then
      ok=1
    else
      warn "邮件推送失败：${resp}"
    fi
  fi
  if [[ -n "${ALERT_TG_TOKEN:-}" && -n "${ALERT_TG_CHAT:-}" ]]; then
    if resp="$(curl -fsS -m 10 "https://api.telegram.org/bot${ALERT_TG_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${ALERT_TG_CHAT}" --data-urlencode "text=${text}" 2>&1)"; then
      ok=1
    else
      warn "Telegram 推送失败：${resp}"
    fi
  fi
  if [[ -n "${ALERT_WEBHOOK:-}" ]]; then
    if resp="$(jq -n --arg t "${text}" '{text: $t}' \
      | curl -fsS -m 10 -H 'Content-Type: application/json' --data-binary @- "${ALERT_WEBHOOK}" 2>&1)"; then
      ok=1
    else
      warn "webhook 推送失败：${resp}"
    fi
  fi
  if [[ "${ok}" == 0 ]]; then
    warn "未配置任何推送通道，告警只写日志"
    return 1
  fi
  return 0
}

alert_check() {
  need_root
  log_is_writable
  local now cooldown problems="" last msg key last_ts cached
  now="$(date +%s)"
  cooldown="${ALERT_COOLDOWN_H:-6}"
  # 探针停摆时最后一行不会自己消失，超龄的旧结论不能拿来报警
  last="$(probe_last_fresh)"

  # 1) 服务与端口：探针 CSV 里出现 down
  if printf '%s' "${last}" | grep -q ',down'; then
    problems="${problems}- 服务或端口异常：${last}%NL%"
  fi
  # 2) AI 出口不可达：403/429 属「连上了但被拦」，不算不可达
  if printf '%s' "${last}" | cut -d, -f8 | grep -qx 'fail'; then
    problems="${problems}- AI 出口不可达：code $(printf '%s' "${last}" | cut -d, -f6)%NL%"
  fi

  # 3) 月流量占比
  local used quota pct
  used="$(month_bytes)"
  quota="$(quota_bytes)"
  if [[ -n "${used}" && -n "${quota}" && "${quota}" != "0" ]]; then
    pct="$(awk -v u="${used}" -v q="${quota}" 'BEGIN { printf "%d", u * 100 / q }')"
    if [[ "${pct}" -ge "${ALERT_TRAFFIC_PCT:-80}" ]]; then
      problems="${problems}- 当月流量 ${pct}%：$(fmt_bytes "${used}")/$(fmt_bytes "${quota}")%NL%"
    fi
  fi

  # 4) 证书到期
  if [[ -r "${DEPLOY_DIR}/cert.pem" ]]; then
    local end days
    end="$(openssl x509 -enddate -noout -in "${DEPLOY_DIR}/cert.pem" 2>/dev/null | cut -d= -f2)"
    if [[ -n "${end}" ]]; then
      days="$((($(date -d "${end}" +%s) - now) / 86400))"
      if [[ "${days}" -le "${ALERT_CERT_DAYS:-14}" ]]; then
        problems="${problems}- 证书 ${days} 天后到期%NL%"
      fi
    fi
  fi

  if [[ -z "${problems}" ]]; then
    printf '无异常项\n'
    return 0
  fi

  msg="$(printf '%s' "${problems}" | sed 's/%NL%/\n/g')"
  key="$(printf '%s' "${msg}" | md5sum | cut -d' ' -f1)"
  if [[ -r "${ALERT_STATE}" ]]; then
    read -r last_ts cached <"${ALERT_STATE}" || true
    if [[ "${cached:-}" == "${key}" ]] && [[ $((now - ${last_ts:-0})) -lt $((cooldown * 3600)) ]]; then
      printf '冷却中，跳过推送\n'
      return 0
    fi
  fi
  printf '%s %s\n' "${now}" "${key}" >"${ALERT_STATE}"
  printf '推送告警：\n%s\n' "${msg}"
  alert_send "${msg}" || true
}

# ---------------------------------------------------------------- 主流程
case "${MODE}" in
  probe)
    run_probe
    exit 0
    ;;
  alertcheck)
    alert_check
    exit 0
    ;;
  alerttest)
    need_root
    alert_send "探针告警测试：来自 $(hostname)" && log "测试告警已发出" && exit 0
    die "测试告警未发出，检查 ALERT_TG_TOKEN/ALERT_TG_CHAT 或 ALERT_WEBHOOK"
    ;;
  status)
    show_status
    exit 0
    ;;
  uninstall)
    need_root
    remove_timer
    log "已卸载观测：探针定时器已移除（探针记录保留）"
    exit 0
    ;;
esac

need_root
log "安装探针定时器"
install_timer
run_probe
show_status
