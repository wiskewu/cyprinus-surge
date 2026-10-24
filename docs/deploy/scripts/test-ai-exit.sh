#!/usr/bin/env bash
# test-ai-exit.sh —— 验证 AI 域名走独立出口这条链路。
#
# AI_MODE=dedicated 分支在没有线上流量时不会暴露问题，本脚本在服务器本机做端到端验证：
#   1. 起临时 socks5 监听 127.0.0.1，充当落地机
#   2. 用现成渲染脚本生成 AI_MODE=dedicated 的客户端配置，只开 mixed
#   3. 起临时 sing-box 实例
#   4. 经 mixed 端口请求 AI 域名，检查日志中的 ai-out
#   5. 关闭进程并删除临时文件
#
# 出口 IP 不变，验证的是路由与出站接线，不是 IP 分离。
#
# 用法：sudo bash test-ai-exit.sh [要测试的域名，默认 https://chatgpt.com/cdn-cgi/trace]
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SELF_DIR}/lib.sh"
need_root
need_cmd curl

TARGET_URL="${1:-https://chatgpt.com/cdn-cgi/trace}"
MIXED_PORT="${MIXED_PORT:-2081}"      # 临时客户端入站
SOCKS_PORT="${SOCKS_PORT:-1081}"      # 临时「落地机」
SOCKS_USER="selftest" ; SOCKS_PASS="selftest"
mktemp_dir TMP
PIDS=""

cleanup() {
  for p in ${PIDS}; do kill "${p}" 2>/dev/null || true; done
  sleep 0.3
  for p in ${PIDS}; do kill -9 "${p}" 2>/dev/null || true; done
  cleanup_tmp_dirs
  return 0
}
trap cleanup EXIT

log "0/5 前置检查"
[[ -x "${SB_BIN}" ]] || die "找不到 ${SB_BIN}，先跑 10-install-singbox.sh"
[[ -s "${CLIENT_ENV}" ]] || die "缺少 ${CLIENT_ENV}，先跑 20-secrets.sh"
for p in "${MIXED_PORT}" "${SOCKS_PORT}"; do
  ss -tln 2>/dev/null | grep -q ":${p} " && die "端口 ${p} 已被占用，换一个：MIXED_PORT= / SOCKS_PORT="
done
command -v ss >/dev/null 2>&1 || warn "没有 ss，跳过端口占用检查"

log "1/5 起临时落地（socks5 → direct，仅本机可达）"
cat >"${TMP}/landing.json" <<JSON
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "socks", "tag": "landing-in",
    "listen": "127.0.0.1", "listen_port": ${SOCKS_PORT},
    "users": [{ "username": "${SOCKS_USER}", "password": "${SOCKS_PASS}" }]
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
JSON
"${SB_BIN}" check -c "${TMP}/landing.json" || die "临时落地配置有误"
"${SB_BIN}" run -c "${TMP}/landing.json" >"${TMP}/landing.log" 2>&1 &
PIDS="${PIDS} $!"

log "2/5 渲染 AI_MODE=dedicated 的客户端配置（只出 mixed，不起 TUN）"
OUT="${TMP}/client.json" \
NO_TUN=1 CLIENT_MIXED=1 \
AI_MODE=dedicated \
AI_SOCKS_SERVER=127.0.0.1 \
AI_SOCKS_PORT="${SOCKS_PORT}" \
AI_SOCKS_USER="${SOCKS_USER}" \
AI_SOCKS_PASS="${SOCKS_PASS}" \
  bash "${SELF_DIR}/50-render-client.sh" "${CLIENT_ENV}" >"${TMP}/render.log" 2>&1 \
  || { cat "${TMP}/render.log" >&2; die "渲染失败"; }
grep -q 'ok' "${TMP}/render.log" || log "（渲染过程未打印 sing-box 校验结果，继续）"

log "3/5 起临时客户端实例"
"${SB_BIN}" run -c "${TMP}/client.json" >"${TMP}/client.log" 2>&1 &
PIDS="${PIDS} $!"
sleep 1
grep -qi 'fatal\|error' "${TMP}/client.log" && { sed -n '1,20p' "${TMP}/client.log" >&2; die "客户端实例起不来"; }

log "4/5 通过 mixed 端口请求 ${TARGET_URL}"
set +e
curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
  --proxy "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${MIXED_PORT}" \
  "${TARGET_URL}" >"${TMP}/code" 2>"${TMP}/curl.err"
CURL_RC=$?
set -e
CODE="$(cat "${TMP}/code" 2>/dev/null || printf 000)"
log "    HTTP ${CODE}，curl 退出码 ${CURL_RC}；403/401 属正常，此处只验证路由"

log "5/5 核对 ai-out 是否真的被用到"
grep -o 'outbound/[a-z0-9_-]*' "${TMP}/client.log" 2>/dev/null | sort -u >"${TMP}/used" || true
log "    客户端用到的出站：$(tr '\n' ' ' <"${TMP}/used" 2>/dev/null || printf '（日志里没有 outbound 记录）')"

FAILED=0
grep -q 'ai-out' "${TMP}/used" 2>/dev/null || FAILED=1
grep -q 'ai-out' "${TMP}/client.json" || FAILED=1   # 兜底：配置里至少要有这条出站

printf '\n'
if [[ "${FAILED}" == 0 ]]; then
  log "通过：AI 域名确实走 ai-out（独立出口）"
  cat <<EOF
  出口 IP 与不走 AI 出口时相同，落地机位于本机。
  验证真正的 IP 分离需要一台远程落地机。
EOF
else
  warn "未通过：AI 域名没有走 ai-out"
  cat <<EOF
  排查：
    1. sing-box 版本是否 ≥1.14（本测试依赖新式 route 规则）
    2. ${TMP}/client.log 里搜 ai-out，看是否有连接错误
    3. 确认 client.env 的 AI_MODE 不是 main（这里用命令行覆盖，应该不受影响）
    4. 确认 curl 能出网：curl -s https://www.gstatic.com/generate_204
EOF
  exit 1
fi