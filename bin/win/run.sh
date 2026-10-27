#!/usr/bin/env bash
# bin/win/run.sh —— 先在 Windows 上校验客户端配置，通过后前台启动 sing-box。
#
# 用法：
#   bash bin/win/run.sh config.json
#   bash bin/win/run.sh config.json --check-only
#   bash bin/win/run.sh config.json --sing-box "D:/sing-box/sing-box.exe"
# 说明：TUN 入站需要管理员权限；非管理员启动会在创建网卡时失败，脚本提前提示。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/common.sh
. "${SELF_DIR}/../lib/common.sh"

usage() {
  cat <<'EOF'
用法：bash bin/win/run.sh <配置.json> [选项]

  --sing-box 路径   指定可执行文件；不给则依次找配置目录、当前目录、PATH
  --check-only      只校验，不启动
  -h, --help        显示本帮助

退出码：0 正常结束；2 参数或文件问题；1 校验不通过或启动失败。
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
CFG="$1"
shift
[[ -f "${CFG}" ]] || die "找不到配置文件：${CFG}"
CFG="$(cd "$(dirname "${CFG}")" && pwd)/$(basename "${CFG}")"

SING_BOX=""
CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sing-box)
      shift
      SING_BOX="${1:?--sing-box 需要可执行文件路径}"
      ;;
    --check-only) CHECK_ONLY=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "未知参数：$1" ;;
  esac
  shift
done

if [[ -z "${SING_BOX}" ]]; then
  for cand in "$(dirname "${CFG}")/sing-box.exe" "./sing-box.exe" "$(dirname "${CFG}")/sing-box"; do
    [[ -x "${cand}" ]] && SING_BOX="${cand}" && break
  done
fi
if [[ -z "${SING_BOX}" ]] && command -v sing-box >/dev/null 2>&1; then SING_BOX="sing-box"; fi
[[ -n "${SING_BOX}" ]] || die "找不到 sing-box 可执行文件，用 --sing-box 指定（例如 --sing-box \"D:/sing-box/sing-box.exe\"）"

[[ -x "${SING_BOX}" ]] || die "不可执行：${SING_BOX}"

log "校验：${CFG}"
if ! "${SING_BOX}" check -c "${CFG}"; then
  die "校验不通过，未启动。上一条输出即失败原因；管控机常见的是 connectex 10049，见排查手册的企业管控一节"
fi

if [[ "${CHECK_ONLY}" == 1 ]]; then
  log "校验通过（--check-only，不启动）"
  exit 0
fi

# TUN 需要管理员：net session 在非提权会话里必然失败。只有配置里真有 TUN 入站时才提示。
if grep -qE '"type"[[:space:]]*:[[:space:]]*"tun"' "${CFG}" && ! net session >/dev/null 2>&1; then
  warn "配置含 TUN 入站，而当前会话不是管理员，创建网卡会失败；以管理员身份重开终端再运行"
fi

log "启动：${SING_BOX} run -c ${CFG}"
exec "${SING_BOX}" run -c "${CFG}"
