#!/usr/bin/env bash
# bin/win/convert.sh —— 把服务器下发的客户端配置改成适配「企业管控」环境的版本。
#
# 背景：部分受管终端禁止直连公共 DNS 的 443 与 853，配置里的国内 DoH 会让
# sing-box 启动即报 connectex: The requested address is not valid in its context。
# 两种改法，二选一：
#   bind   给 direct 出站加 inet4_bind_address，用源地址绑定代替接口绑定
#   local  把国内 DNS 换成 {"type":"local"}，交给系统解析
#
# 用法：
#   bash bin/win/convert.sh 客户端配置.json --mode bind
#   bash bin/win/convert.sh 客户端配置.json --mode local --out ./config.json
# 依赖：node（做 JSON 改写）；装了 sing-box 时会顺带校验产物。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SELF_DIR}/../lib/common.sh"

usage() {
  cat <<'EOF'
用法：bash bin/win/convert.sh <源配置.json> [选项]

  --mode bind|local   必填。bind：direct 出站指定源地址；local：国内解析交给系统
  --bind-address IP   仅 bind 模式。默认取默认路由网卡的 IPv4
  --out 路径          输出文件，默认 <源配置名>-<mode>.json（同目录）
  --sing-box 路径     指定可执行文件；不给则依次找配置目录、当前目录、PATH
  --no-check          生成后不校验
  -h, --help          显示本帮助

产出可直接交给 run.sh 启动。两种改写都不改动服务器下发的原文件。
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

[[ $# -ge 1 ]] || {
  usage
  exit 2
}
SRC="$1"
shift
[[ -f "${SRC}" ]] || die "找不到配置文件：${SRC}"

MODE=""
BIND_ADDR=""
OUT=""
SING_BOX=""
DO_CHECK=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      shift
      MODE="${1:?--mode 需要 bind 或 local}"
      ;;
    --bind-address)
      shift
      BIND_ADDR="${1:?--bind-address 需要 IPv4 地址}"
      ;;
    --out)
      shift
      OUT="${1:?--out 需要路径}"
      ;;
    --sing-box)
      shift
      SING_BOX="${1:?--sing-box 需要可执行文件路径}"
      ;;
    --no-check) DO_CHECK=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "未知参数：$1" ;;
  esac
  shift
done
case "${MODE}" in
  bind | local) ;;
  "") usage_error "缺少 --mode" ;;
  *) usage_error "--mode 只能是 bind 或 local，收到：${MODE}" ;;
esac

need_cmd node
SRC_DIR="$(cd "$(dirname "${SRC}")" && pwd)"
SRC_NAME="$(basename "${SRC}" .json)"
OUT="${OUT:-${SRC_DIR}/${SRC_NAME}-${MODE}.json}"

# bind 模式的源地址：取默认路由网卡上的 IPv4。用 PowerShell 读，避免解析 ipconfig 的中文输出。
# PowerShell 里的 $_ 与 $null 由 PowerShell 解析，不经 bash 展开
# shellcheck disable=SC2016
detect_bind_address() {
  local addr
  addr="$(powershell -NoProfile -Command \
    '(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null } | Select-Object -First 1).IPv4Address.IPAddress' \
    2>/dev/null | tr -d '\r' | head -1)"
  [[ -n "${addr}" ]] || return 1
  printf '%s' "${addr}"
}

if [[ "${MODE}" == "bind" ]]; then
  if [[ -z "${BIND_ADDR}" ]]; then
    BIND_ADDR="$(detect_bind_address)" || die "自动识别本机 IPv4 失败，用 --bind-address 显式给出（ipconfig 里「IPv4 地址」那一项）"
  fi
  [[ "${BIND_ADDR}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--bind-address 不是合法 IPv4：${BIND_ADDR}"
fi

# 改写交给 node：配置里的中文标签与嵌套结构用 sed 改不可靠。
node - "${SRC}" "${OUT}" "${MODE}" "${BIND_ADDR}" <<'NODE_EOF'
const fs = require('fs');
const [, , srcPath, outPath, mode, bindAddress] = process.argv;
const cfg = JSON.parse(fs.readFileSync(srcPath, 'utf8'));

if (mode === 'bind') {
  const direct = (cfg.outbounds ?? []).find((o) => o.type === 'direct');
  if (!direct) throw new Error('配置里没有 type 为 direct 的出站，无法指定源地址');
  if (direct.inet4_bind_address === bindAddress) {
    console.log(`已是指定源地址版本：${bindAddress}`);
  } else {
    direct.inet4_bind_address = bindAddress;
    console.log(`direct 出站已指定源地址：${bindAddress}`);
  }
} else {
  const servers = cfg.dns?.servers;
  if (!Array.isArray(servers) || servers.length === 0) throw new Error('配置里没有 dns.servers，无法改为系统解析');
  const cn = servers.find((s) => s.tag === 'dns-cn');
  if (!cn) throw new Error('配置里没有 tag 为 dns-cn 的 DNS 服务器');
  if (cn.type === 'local') {
    console.log('国内 DNS 已交给系统解析，未改动');
  } else {
    for (const key of Object.keys(cn)) delete cn[key];
    Object.assign(cn, { type: 'local', tag: 'dns-cn' });
    console.log('国内 DNS 已改为系统解析：{"type":"local","tag":"dns-cn"}');
  }
}

fs.writeFileSync(outPath, `${JSON.stringify(cfg, null, 2)}\n`);
NODE_EOF

printf '\n输出：%s\n' "${OUT}"

if [[ "${DO_CHECK}" == 1 ]]; then
  # 依次在配置目录、当前目录与 PATH 里找可执行文件
  if [[ -z "${SING_BOX}" ]]; then
    for cand in "${SRC_DIR}/sing-box.exe" "$(dirname "${OUT}")/sing-box.exe" "./sing-box.exe"; do
      [[ -x "${cand}" ]] && SING_BOX="${cand}" && break
    done
  fi
  if [[ -z "${SING_BOX}" ]] && command -v sing-box >/dev/null 2>&1; then SING_BOX="sing-box"; fi
  if [[ -n "${SING_BOX}" ]]; then
    "${SING_BOX}" check -c "${OUT}" && log "校验通过：${OUT}"
  else
    warn "没找到 sing-box 可执行文件，跳过校验；用 --sing-box 指定"
  fi
fi

log "启动：bash ${SELF_DIR}/run.sh ${OUT}"
