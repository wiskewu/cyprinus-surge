#!/usr/bin/env bash
# bin/deploy/client/install.sh —— 客户端一键复位：SSH 免密、渲染配置、验收。
#
#   bash bin/deploy/client/install.sh --keys client.env
#   bash bin/deploy/client/install.sh --keys laptop.env --device laptop \
#        --ssh-host 203.0.113.10 --ssh-port 4061
#   bash bin/deploy/client/install.sh --keys client.env --skip-ssh --proxy socks5h://127.0.0.1:7890
#
# 三步都可单独跳过。没有任何一步需要 root：SSH 密钥写在用户目录，配置渲染到 data/。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib.sh
. "${SELF_DIR}/../lib.sh"

KEYS="${KEYS:-./client.env}"
DEVICE=""
SSH_HOST=""
SSH_PORT=""
SSH_ALIAS="vps"
PROXY="${PROXY:-}"
SKIP_SSH=0
SKIP_VERIFY=0
VERIFY_NO_CLI=0
CHECK=0
ROLLBACK=0

usage() {
  cat <<'EOF'
用法：bash bin/deploy/client/install.sh --keys <client.env> [选项]

  --keys FILE       客户端密钥包（device.sh add 生成的那份）
  --device NAME     渲染指定设备的配置；不给则按包里的默认设备
  --ssh-host ADDR   顺带做 SSH 免密：装公钥并写 ~/.ssh/config
  --ssh-port N      SSH 端口，默认 22
  --ssh-alias NAME  写入 ~/.ssh/config 的别名，默认 vps
  --skip-ssh        跳过 SSH 免密
  --proxy URL       验收用的本地代理，例如 socks5h://127.0.0.1:7890
  --no-cli          验收走免 CLI 子集，适合图形客户端
  --skip-verify     跳过验收
  --check           只报告本机依赖与文件，不做改动
  --rollback        用 data/previous 里最近一版配置替换 data/ 下的文件，不重新渲染
  -h, --help        显示帮助

顺序：SSH 免密 → 渲染配置 → 验收。任一步失败即停止并打印原因。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keys)
      shift
      KEYS="${1:?--keys 需要文件}"
      ;;
    --device)
      shift
      DEVICE="${1:?--device 需要名字}"
      ;;
    --ssh-host)
      shift
      SSH_HOST="${1:?--ssh-host 需要地址}"
      ;;
    --ssh-port)
      shift
      SSH_PORT="${1:?--ssh-port 需要端口}"
      ;;
    --ssh-alias)
      shift
      SSH_ALIAS="${1:?--ssh-alias 需要名字}"
      ;;
    --proxy)
      shift
      PROXY="${1:?--proxy 需要地址}"
      ;;
    --skip-ssh) SKIP_SSH=1 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    --no-cli) VERIFY_NO_CLI=1 ;;
    --check) CHECK=1 ;;
    --rollback) ROLLBACK=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "未知参数：$1" ;;
  esac
  shift
done

# 回滚只动配置文件，跟 SSH 与验收无关
if [[ "${ROLLBACK}" == 1 ]]; then
  SKIP_SSH=1
  SKIP_VERIFY=1
fi

report() {
  printf '平台        : %s %s\n' "$(uname -s)" "$(uname -m)"
  printf '密钥包      : %s\n' "$([[ -f "${KEYS}" ]] && printf '存在' || printf '缺失')"
  printf 'curl        : %s\n' "$(command -v curl >/dev/null 2>&1 && printf '有' || printf '缺失')"
  printf 'jq          : %s\n' "$(command -v jq >/dev/null 2>&1 && printf '有' || printf '缺失，渲染会失败')"
  printf 'sing-box    : %s\n' "$(command -v sing-box >/dev/null 2>&1 && printf '有' || printf '无，验收只能用 --no-cli')"
  printf 'SSH 密钥    : %s\n' "$([[ -f "${HOME}/.ssh/id_ed25519" ]] && printf '存在' || printf '不存在')"
  printf 'SSH 别名    : %s\n' "$(grep -q "^Host ${SSH_ALIAS}$" "${HOME}/.ssh/config" 2>/dev/null && printf '%s 已配置' "${SSH_ALIAS}" || printf '未配置')"
}

if [[ "${CHECK}" == 1 ]]; then
  report
  exit 0
fi

if [[ $# -eq 0 ]] && [[ -t 0 ]] && [[ ! -f "${KEYS}" ]]; then
  ui_ask "客户端密钥包路径" "./client.env"
  KEYS="${UI_ANSWER}"
fi

need_cmd curl
[[ "${ROLLBACK}" == 1 ]] || command -v jq >/dev/null 2>&1 || die "缺少 jq：渲染配置与验收都要用（macOS: brew install jq，Debian: apt install jq）"
[[ "${ROLLBACK}" == 1 ]] || [[ -f "${KEYS}" ]] || die "找不到密钥包 ${KEYS}，先从服务器取一份 clients/<名字>.env"

# ---------------------------------------------------------------- 1. SSH 免密
if [[ "${SKIP_SSH}" == 0 ]] && [[ -n "${SSH_HOST}" ]]; then
  log "1/3 SSH 免密：${SSH_ALIAS} → ${SSH_HOST}${SSH_PORT:+:${SSH_PORT}}"
  args=(--host "${SSH_HOST}" --alias "${SSH_ALIAS}" --install-server)
  [[ -n "${SSH_PORT}" ]] && args+=(--port "${SSH_PORT}")
  bash "${SELF_DIR}/../../harden/client.sh" "${args[@]}"
elif [[ "${SKIP_SSH}" == 0 ]]; then
  log "1/3 跳过 SSH 免密：没给 --ssh-host"
else
  log "1/3 SSH 免密按参数跳过"
fi

# ---------------------------------------------------------------- 2. 渲染配置
# 与 render.sh 的默认输出目录一致：相对当前工作目录的 data/
DATA_DIR="${DATA_DIR:-data}"
PREV_DIR="${DATA_DIR}/previous"

if [[ "${ROLLBACK}" == 1 ]]; then
  log "2/3 回滚到上一版配置"
  last="$(find "${PREV_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
  [[ -n "${last}" ]] || die "没有可回滚的版本：${PREV_DIR} 为空"
  if compgen -G "${last}/*.json" >/dev/null 2>&1; then
    cp -f "${last}"/*.json "${DATA_DIR}/"
  else
    die "上一版目录里没有配置：${last}"
  fi
  log "    已还原 $(basename "${last}") 下的配置"
else
  log "2/3 渲染客户端配置"
  # 覆盖前留一版：渲染失败或客户端跑不起来时可以 --rollback
  if compgen -G "${DATA_DIR}/*.json" >/dev/null 2>&1; then
    snap="${PREV_DIR}/$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 700 "${snap}"
    cp -f "${DATA_DIR}"/*.json "${snap}/" 2>/dev/null || true
    # 只留最近三版，避免无限堆积
    find "${PREV_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n -3 | xargs -r rm -rf
    log "    上一版已存 ${snap}"
  fi
  render_args=("${KEYS}")
  [[ -n "${DEVICE}" ]] && render_args+=(--device "${DEVICE}")
  bash "${SELF_DIR}/render.sh" "${render_args[@]}"
fi

# ---------------------------------------------------------------- 3. 验收
if [[ "${SKIP_VERIFY}" == 1 ]]; then
  log "3/3 验收按参数跳过"
else
  log "3/3 验收"
  verify_args=()
  if [[ "${VERIFY_NO_CLI}" == 1 ]]; then
    verify_args+=(--no-cli)
  fi
  [[ -n "${PROXY}" ]] && verify_args+=(--proxy "${PROXY}")
  if bash "${SELF_DIR}/verify.sh" "${verify_args[@]}" "${KEYS}"; then
    log "验收通过"
  else
    warn "验收有失败项，先按上面的定位排查；配置已渲染，可先导入客户端再复测"
    exit 1
  fi
fi

cat <<EOF

客户端就绪。接下来：
  1) 把 data/ 下对应的 JSON 导入客户端（SFM / GUI.for.SingBox 都支持导入 sing-box 配置）
  2) 打开客户端，确认本地 mixed 端口，再跑一次验收：
     bash ${SELF_DIR}/verify.sh --no-cli --proxy socks5h://127.0.0.1:<端口>
  3) SSH 免密成功后可直接 ssh ${SSH_ALIAS}
EOF
