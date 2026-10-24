#!/usr/bin/env bash
# 60-verify-client.sh —— 在【客户端机器】做验收测试（用本地 mixed 入站，不需要 TUN）。
# 用法： bash 60-verify-client.sh client.env
#       PROXY=socks5h://127.0.0.1:20122 bash 60-verify-client.sh client.env   # GUI 的端口
#       SERVER_IP=1.2.3.4 VLESS_PORT=443 bash 60-verify-client.sh             # 没 client.env（device.sh 流程）
#       HY2_ONLY=1 CONFIG=client.json bash 60-verify-client.sh client.env     # 只测 Hysteria2 出站
#       HY2_ONLY=emit CONFIG=client.json HY2_OUT=hy2.json bash 60-verify-client.sh  # 只生成配置给图形客户端导入
#
# 设计原则：
#   1) 代理不通就直接停（exit 2），不打印一堆误导性的结果
#   2) 只在拿到真实数据时才记 ✓；空值 / HTTP 000 一律算失败
#   3) 不依赖 nc / mtr / 第三方 IP 回显站
#   4) 走 SOCKS 时 time_connect 只是到本地代理的几毫秒，不能当路径指标
#   5) HY2_ONLY=1：只拿 Hysteria2 出站跑一遍，用来证明第二入口真的能用
set -uo pipefail   # 验收脚本要跑完全部检查项，故不启用 -e
CLIENT_ENV_FILE="${1:-./client.env}"
ENVFILE="${CLIENT_ENV_FILE}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SELF_DIR}/lib.sh"
PROXY="${PROXY:-socks5h://127.0.0.1:2080}"
# HY2_ONLY=1：不改手上那份配置，从 CONFIG 派生一份只留 Hysteria2 出站的副本，
# 用临时 mixed 端口前台跑起来再验收。端口与 tag 都能改。
HY2_ONLY="${HY2_ONLY:-0}"
CONFIG="${CONFIG:-./client.json}"
HY2_TAG="${HY2_TAG:-proxy-hy2}"
HY2_PROBE_PORT="${HY2_PROBE_PORT:-2081}"
# 没有 CLI 的图形客户端（SFM / GUI.for.SingBox）把核心装在扩展或 App 里，
# 那条路要走 GUI 侧的出站选择，见 docs/deploy/04-hy2.html#verify。
SING_BOX_BIN="${SING_BOX_BIN:-sing-box}"
# HY2_ONLY=emit 时写出的文件；留空则落在当前目录 hy2-only.json
HY2_OUT="${HY2_OUT:-}"
# 环境文件可有可无：脚本真正用到的只有 SERVER_IP / VLESS_PORT。
# 用 device.sh 管设备时，客户端手上只有一份 JSON，没必要（也不应该）把 client.env 发过去，
# 这时直接给变量：SERVER_IP=1.2.3.4 VLESS_PORT=443 bash 60-verify-client.sh
if [[ "${HY2_ONLY}" == "emit" ]] && [[ ! -f "${ENVFILE}" ]] && [[ -z "${SERVER_IP:-}" ]]; then
  # 只生成配置、不联网，SERVER_IP / client.env 都用不到
  printf '\033[33m[!]\033[0m HY2_ONLY=emit 只写文件、不联网，跳过 %s\n' "${ENVFILE}" >&2
elif [[ -f "${ENVFILE}" ]]; then
  load_env "${ENVFILE}"
elif [[ -n "${SERVER_IP:-}" ]]; then
  printf '\033[33m[!]\033[0m 没有 %s，按命令行给的 SERVER_IP / VLESS_PORT 继续\n' "${ENVFILE}" >&2
else
  die "找不到 ${ENVFILE}，从服务器 /etc/sing-box/client.env 复制一份，或用 SERVER_IP= VLESS_PORT= 直接给"
fi
SERVER_IP="${SERVER_IP:-}"
VLESS_PORT="${VLESS_PORT:-443}"

PASS=0; FAIL=0; SKIP=0

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
no()   { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '  \033[36m·\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }
# 只接受数字与小数点，防止把 HTML 之类的东西喂给 printf/awk
num()  { case "${1:-}" in ''|*[!0-9.]*) echo 0 ;; *) echo "$1" ;; esac; }

# 同一个 URL 请求两次：第 1 次冷启动，第 2 次复用连接。
# 注意 -o 是按位置的：两个 URL 就要两个 -o，否则第二个响应正文会打到 stdout。
probe() {
  curl --proxy "${PROXY}" -sS --max-time "${2:-25}" \
    -o /dev/null "$1" -o /dev/null "$1" \
    -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n' \
    2>/dev/null || true
}
# 单个 URL，输出 "<code> <ttfb>"
one() {
  curl --proxy "${PROXY}" -sS --max-time "${2:-15}" -o /dev/null \
    -w '%{http_code} %{time_starttransfer}' "$1" 2>/dev/null || true
}
body() {
  curl --proxy "${PROXY}" -fsS --max-time "${2:-12}" "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------- HY2_ONLY
# 派生配置：把所有指向其它代理出站的引用改写成目标 tag，再裁到只剩目标与 direct；
# 入站只留一个本地 mixed 端口，这样不需要 root、不和 GUI 抢 TUN。
port_open() {
  local p="$1"
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "${p}" >/dev/null 2>&1
    return
  fi
  # 没有 nc 时退回到 bash 的内建 TCP 连接（bash 3.2 起可用）
  if (exec 3<>"/dev/tcp/127.0.0.1/${p}") >/dev/null 2>&1; then
    exec 3<&- 3>&- 2>/dev/null || true
    return 0
  fi
  return 1
}

# 派生配置：只改「引用其它代理出站」的那几处，不能整篇替换字符串——出站自己的
# tag 也叫 proxy / auto，一起换掉会造出重复 tag，sing-box 直接拒绝启动。
# $3 = local：入站换成一个本地 mixed 端口，前台跑、不用 root。
# $3 = keep ：入站原样保留，给图形客户端导入用。
derive_hy2_config() {
  local cfg="$1" out="$2" inb="$3"
  jq --arg t "${HY2_TAG}" --argjson p "${HY2_PROBE_PORT}" --arg inb "${inb}" '
    def ref: if . == "auto" or . == "proxy" or . == "ai-out" then $t else . end;
    .route.final = ((.route.final // $t) | ref)
    | (.route.rules? // []) |= map(if has("outbound") then .outbound |= ref else . end)
    | (.route.rule_set? // []) |= map(if has("download_detour") then .download_detour |= ref else . end)
    | (.http_clients? // []) |= map(if has("detour") then .detour |= ref else . end)
    | (.dns.servers? // []) |= (
        if type == "array" then map(if has("detour") then .detour |= ref else . end)
        elif type == "object" then with_entries(.value |= (if has("detour") then .detour |= ref else . end))
        else . end)
    | .outbounds = [ .outbounds[] | select(.tag == $t or .tag == "direct") ]
    | (if $inb == "local" then
         .inbounds = [ { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: $p } ]
       else . end)
  ' "${cfg}" >"${out}"
}

# HY2_ONLY=emit：只生成文件，不起进程、不需要 sing-box。给 SFM / GUI.for.SingBox 导入用。
emit_hy2_only() {
  need_cmd jq
  [[ -f "${CONFIG}" ]] || die "CONFIG 指向的客户端配置不存在：${CONFIG}"
  jq -e --arg t "${HY2_TAG}" 'any(.outbounds[]; .tag == $t)' "${CONFIG}" >/dev/null 2>&1 ||
    die "${CONFIG} 里没有出站 ${HY2_TAG}，这份配置没启用 Hysteria2"
  local out="${HY2_OUT:-hy2-only.json}"
  derive_hy2_config "${CONFIG}" "${out}" keep
  jq -e '.route.final and ([.outbounds[].tag] | unique | length) == 2' "${out}" >/dev/null ||
    die "派生结果校验失败：${out}"
  printf '  \033[32m✓\033[0m 已生成只走 %s 的配置：%s\n' "${HY2_TAG}" "${out}"
  printf '  \033[36m·\033[0m 出站：%s；入站原样保留，导入图形客户端即用它自己的 TUN\n' \
    "$(jq -c '[.outbounds[].tag]' "${out}")"
  cat <<EOF

下一步：
  1) 把 ${out} 导入客户端（SFM / GUI.for.SingBox 都是导入 sing-box 配置）
  2) 确认客户端已按这份配置启动，再看它的本地 mixed 端口
  3) PROXY=socks5h://127.0.0.1:<该端口> SERVER_IP=<服务器IP> bash $0

要命令行直接跑、不导入客户端： HY2_ONLY=1（需要本机有 sing-box）
EOF
  exit 0
}

cleanup_hy2() {
  [[ -n "${SB_PID:-}" ]] && { kill "${SB_PID}" 2>/dev/null || true; wait "${SB_PID}" 2>/dev/null || true; }
  [[ -n "${TMP_DIR:-}" ]] && rm -rf "${TMP_DIR}"
  return 0
}

start_hy2_only() {
  need_cmd jq
  if ! command -v "${SING_BOX_BIN}" >/dev/null 2>&1; then
    die "HY2_ONLY=1 需要一个能跑 -c 的 sing-box：brew install sing-box / apt install sing-box
       已装图形客户端但没有 CLI 时，两条路选一条：
       1) 装 CLI：brew install sing-box，或把已有的二进制路径给 SING_BOX_BIN=/path/to/sing-box
       2) 不装：在客户端里把出站选择改成只走 ${HY2_TAG}，然后直接跑
          PROXY=socks5h://127.0.0.1:<端口> SERVER_IP=<服务器IP> bash $0"
  fi
  [[ -f "${CONFIG}" ]] || die "CONFIG 指向的客户端配置不存在：${CONFIG}"
  jq -e --arg t "${HY2_TAG}" 'any(.outbounds[]; .tag == $t)' "${CONFIG}" >/dev/null 2>&1 ||
    die "${CONFIG} 里没有出站 ${HY2_TAG}，这份配置没启用 Hysteria2"
  if port_open "${HY2_PROBE_PORT}"; then
    die "127.0.0.1:${HY2_PROBE_PORT} 已被占用，换端口：HY2_PROBE_PORT=2082 bash $0 ..."
  fi

  TMP_DIR="$(mktemp -d)"
  trap cleanup_hy2 EXIT INT TERM
  derive_hy2_config "${CONFIG}" "${TMP_DIR}/hy2-only.json" local

  printf '  \033[36m·\033[0m HY2_ONLY=1：只保留出站 %s，入站 127.0.0.1:%s\n' "${HY2_TAG}" "${HY2_PROBE_PORT}"
  if ! "${SING_BOX_BIN}" check -c "${TMP_DIR}/hy2-only.json" >"${TMP_DIR}/check.log" 2>&1; then
    printf '  \033[31m✗\033[0m 派生配置未通过 sing-box check：\n' >&2
    sed 's/^/      /' "${TMP_DIR}/check.log" >&2
    exit 2
  fi

  "${SING_BOX_BIN}" run -c "${TMP_DIR}/hy2-only.json" >"${TMP_DIR}/run.log" 2>&1 &
  SB_PID=$!
  # 只探测一次就记结果：反复 connect 会打扰刚起来的监听端
  local _wait=0 _up=0
  while [[ "${_wait}" -lt 40 ]]; do
    if port_open "${HY2_PROBE_PORT}"; then _up=1; break; fi
    kill -0 "${SB_PID}" 2>/dev/null || break
    sleep 0.25
    _wait=$((_wait + 1))
  done
  if [[ "${_up}" != 1 ]]; then
    printf '  \033[31m✗\033[0m 临时实例没起来，日志尾部：\n' >&2
    tail -n 15 "${TMP_DIR}/run.log" 2>/dev/null | sed 's/^/      /' >&2
    exit 2
  fi
  PROXY="socks5h://127.0.0.1:${HY2_PROBE_PORT}"
  printf '  \033[32m✓\033[0m 临时实例已监听 %s（日志 %s）\n' "${PROXY}" "${TMP_DIR}/run.log"
}

if [[ "${HY2_ONLY}" == "emit" ]]; then
  say "HY2_ONLY=emit：生成只走 ${HY2_TAG} 的配置，供图形客户端导入"
  emit_hy2_only
fi
if [[ "${HY2_ONLY}" == "1" ]]; then
  say "HY2_ONLY：先起一个只走 ${HY2_TAG} 的临时实例"
  start_hy2_only
fi

say "0. 本地代理是否可用（${PROXY}）"
first="$(body https://api.ipify.org 12)"
if [[ -z "${first}" ]]; then
  printf '  \033[31m✗\033[0m 无法通过 %s 完成任何请求\n' "${PROXY}"
  cat <<'EOF'

  代理没起来，后面的检查都会失真，所以这里直接停。按顺序排查：
    1) 客户端核心启动了吗？报 missing tags / duplicate outbound tag 就是没起来
    2) 端口对吗？GUI.for.SingBox 默认 20122，我们自己生成的配置是 2080
    3) 配置里有 mixed 入站吗？手机配置（CLIENT_MIXED=0）只有 TUN，没有本地端口
    4) 换端口跑：PROXY=socks5h://127.0.0.1:端口 bash 60-verify-client.sh client.env
    5) 用 device.sh 管设备时根本没 client.env：SERVER_IP=服务器IP VLESS_PORT=443 bash 60-verify-client.sh
EOF
  exit 2
fi
ok "代理可用，境外出口 ${first}"
if [[ "${first}" == "${SERVER_IP}" ]]; then
  ok "境外流量确实走 VPS（${SERVER_IP}）"
else
  no "境外出口是 ${first}，不是 SERVER_IP=${SERVER_IP}（检查 client.env 与配置是否同源）"
fi

say "1. 分流：国内站点是否直连（A/B 对照，不依赖第三方）"
# 同一条命令跑两次：--noproxy（基线）与走代理，比 ttfb。
# 走 SOCKS 时 time_connect 只是到本地代理的几毫秒，所以只能比 ttfb。
for host in https://www.baidu.com https://www.qq.com; do
  d="$(curl -sS -o /dev/null --noproxy '*' --max-time 12 -w '%{http_code} %{time_starttransfer}' "${host}" 2>/dev/null || true)"
  p="$(curl --proxy "${PROXY}" -sS -o /dev/null --max-time 12 -w '%{http_code} %{time_starttransfer}' "${host}" 2>/dev/null || true)"
  read -r dcode dtfb <<<"${d}"
  read -r pcode ptfb <<<"${p}"
  dcode="${dcode:-000}"; pcode="${pcode:-000}"
  dtfb="$(num "${dtfb}")"; ptfb="$(num "${ptfb}")"
  if [[ "${pcode}" == "000" ]]; then
    no "${host} 经代理不可达（代理自身能通的话，多半是「直连出口」解析失败，见下方 DNS 提示）"
  elif [[ "${dcode}" != "000" ]] && awk -v t="${dtfb}" 'BEGIN{exit !(t>0)}'; then
    verdict="$(awk -v d="${dtfb}" -v p="${ptfb}" 'BEGIN{ x=p-d; if (x<0.08 && x>-0.08) print "same"; else if (x>0.20) print "tunnel"; else print "unclear" }')"
    case "${verdict}" in
      same)    ok   "${host} 直连 ${dtfb}s / 走代理 ${ptfb}s → 分流生效（未绕行）" ;;
      tunnel)  no   "${host} 直连 ${dtfb}s / 走代理 ${ptfb}s → 被绕进隧道（多 $(awk -v d="${dtfb}" -v p="${ptfb}" 'BEGIN{printf "%.0f",(p-d)*1000}')ms）" ;;
      *)       note "${host} 直连 ${dtfb}s / 走代理 ${ptfb}s → 差异不明显，看连接列表确认" ;;
    esac
  else
    if awk -v t="${ptfb}" 'BEGIN{exit !(t>0 && t<0.15)}'; then
      ok   "${host} 走代理 ${ptfb}s → 直连（国内站点通常 20–100ms）"
    elif awk -v t="${ptfb}" 'BEGIN{exit !(t>=0.25)}'; then
      no   "${host} 走代理 ${ptfb}s → 像被送进隧道（国内站点不应超过 250ms）"
    else
      note "${host} 走代理 ${ptfb}s → 拿不到直连基线，无法判定，看连接列表"
    fi
  fi
done
note "100% 确认：看连接列表的 chains（GUI「连接」页，或 Clash API /connections，见 06-ops）"

say "2. 延迟分解（冷启动 vs 复用连接）"
note "同一个 URL 请求两次：第 1 次冷启动，第 2 次复用连接（后者才是浏览体感）"
for host in https://www.google.com https://www.youtube.com; do
  out="$(probe "${host}")"
  cold="$(printf '%s\n' "${out}" | sed -n '1p')"
  warm="$(printf '%s\n' "${out}" | sed -n '2p')"
  read -r c_code c_dns c_local c_tls c_ttfb c_total <<<"${cold}"
  w_ttfb="$(printf '%s\n' "${warm}" | awk '{print $5}')"
  c_code="${c_code:-000}"
  c_dns="$(num "${c_dns}")"; c_local="$(num "${c_local}")"; c_tls="$(num "${c_tls}")"
  c_ttfb="$(num "${c_ttfb}")"; c_total="$(num "${c_total}")"; w_ttfb="$(num "${w_ttfb}")"
  if [[ "${c_code}" == "000" ]] || [[ "${c_ttfb}" == "0" ]]; then
    no "${host} 请求失败（连不上或 TLS 未完成）"
    continue
  fi
  printf '    \033[2m冷启动 dns=%.3fs 本地=%.3fs TLS完成=%.3fs ttfb=%.3fs total=%.3fs\033[0m\n' \
    "${c_dns}" "${c_local}" "${c_tls}" "${c_ttfb}" "${c_total}"
  printf '    \033[2m复用连接 ttfb=%.3fs\033[0m\n' "${w_ttfb}"
  if awk -v w="${w_ttfb}" 'BEGIN{exit !(w>0 && w<0.5)}' && awk -v c="${c_ttfb}" 'BEGIN{exit !(c<1.2)}'; then
    ok "$(printf '%-26s' "${host}") 复用 ${w_ttfb}s，冷启动 ${c_ttfb}s，HTTP ${c_code}"
  else
    no "$(printf '%-26s' "${host}") 复用 ${w_ttfb}s / 冷启动 ${c_ttfb}s（预期 <0.5s / <1.2s）"
    # 走 SOCKS 时“本地连接”只是到 127.0.0.1 的几毫秒；有意义的是 TLS 完成时间。
    awk -v a="${c_tls}" -v t="${c_ttfb}" 'BEGIN{
      printf "      定位：TLS 完成 %.0fms（含隧道内 DNS+TCP+TLS），首包再 %.0fms\n", a*1000, (t-a)*1000
      if (a > 0.70) print "      → TLS 阶段偏长：多半是丢包重传或晚高峰拥塞（RTT 130ms 时正常应在 260–520ms）"
      else if ((t-a) > 0.45) print "      → TLS 正常、首包慢：是目标站点或 VPS 出口的问题，不是你的线路"
      else print "      → 两段都正常：冷启动被 DNS+新建连接放大，看复用行即可"
    }'
  fi
done

say "3. DNS 是否被接管"
note "mixed 模式下 DNS 由配置里的 dns 段接管，命令行测不准；请用浏览器打开 dnsleaktest.com 复验"
note "另外：如果同时开着两个代理客户端（如 Clash Verge + GUI.for.SingBox），DNS 会被抢，国内域名会解析失败"

say "4. AI 站点可达性"
read -r code _ <<<"$(one https://chatgpt.com)"
code="${code:-000}"
if [[ "${code}" == "000" ]]; then
  no "chatgpt.com 请求失败（根本不是 HTTP 错误，而是没连上）"
elif [[ "${code}" == "403" ]] || [[ "${code}" == "401" ]] || [[ "${code}" == "429" ]]; then
  no "chatgpt.com 返回 ${code}，连接成功但被风控，需更换 AI 出口"
else
  ok "chatgpt.com 返回 ${code}"
fi
read -r code _ <<<"$(one https://www.youtube.com)"
code="${code:-000}"
if [[ "${code}" == "200" ]]; then ok "youtube.com 200"; else no "youtube.com 返回 ${code}"; fi

say "5. 到服务器的握手质量（客户端 → VPS）"
# Windows 上的 mtr/ping 可能 "exit 0 但只打一行报错"，所以只能看输出里有没有真实数据
lat_ok=0; try_out=""
if command -v mtr >/dev/null 2>&1; then
  try_out="$(mtr -rwzc 20 -P "${VLESS_PORT:-443}" "${SERVER_IP}" 2>&1 || true)"
  if printf '%s' "${try_out}" | grep -q 'Loss%'; then
    printf '%s\n' "${try_out}" | tail -3 | sed 's/^/  /'; lat_ok=1
  fi
fi
if [[ "${lat_ok}" == 0 ]]; then
  for flag in -c -n; do   # -c 用于 GNU/macOS，-n 用于 Windows ping
    try_out="$(ping "${flag}" 10 "${SERVER_IP}" 2>&1 || true)"
    if printf '%s' "${try_out}" | grep -qiE 'ttl=|rtt'; then
      printf '%s\n' "${try_out}" | tail -2 | sed 's/^/  /'; lat_ok=1; break
    fi
  done
fi
[[ "${lat_ok}" == 0 ]] && note "本机没有可用的 mtr / ping（Windows 上常见，不影响其它验收）"

say "6. 出口是否稳定（连测 5 次）"
ips=""
for _ in 1 2 3 4 5; do
  ip="$(body https://api.ipify.org 10)"
  [[ -n "${ip}" ]] && ips="${ips} ${ip}"
done
got="$(tr ' ' '\n' <<<"${ips}" | grep -c . || true)"
uniq_n="$(tr ' ' '\n' <<<"${ips}" | grep . | sort -u | grep -c . || true)"
if [[ "${got:-0}" -lt 3 ]]; then
  no "5 次里只成功 ${got:-0} 次，网络不稳定"
elif [[ "${uniq_n}" -eq 1 ]]; then
  ok "5 次出口一致：$(tr ' ' '\n' <<<"${ips}" | grep . | sort -u)"
else
  no "出口 IP 在变，${uniq_n} 个不同值：$(tr ' ' '\n' <<<"${ips}" | grep . | sort -u | paste -sd' ' -)"
fi

printf '\n通过 %d 项，失败 %d 项，跳过 %d 项\n' "${PASS}" "${FAIL}" "${SKIP}"
if [[ "${FAIL}" -eq 0 ]]; then
  printf '\033[32m验收通过。\033[0m\n'
else
  printf '\033[33m有失败项：先看第 0/1 项（代理与分流），再看 06-ops.html 的故障手册。\033[0m\n'
  exit 1
fi
