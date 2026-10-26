# shellcheck shell=bash
# shellcheck disable=SC2034  # 步骤元数据与跨文件变量经 ${!var} 读取
# ============================================================================
# 驱动：由 build-onekey.sh 拼接到 deploy.sh 末尾。不要单独执行本文件。
# ============================================================================
OPT_REUSE=0
OPT_OVERWRITE=0
OPT_YES=0
OPT_DRY=0
OPT_UNINSTALL=0
OPT_REINSTALL=0
OPT_STATUS=0
OPT_ROTATE_SECRETS=0
ONLY=""
SKIP=""
INTERACTIVE=1
PURGE=0

usage() {
  cat <<'USAGE'
用法：sudo bash deploy.sh [选项]

不带选项 → 交互模式：先扫描每一步的状态，再逐个询问「复用 / 覆盖 / 跳过」。

  --reuse            已配置的步骤直接复用（不提问）
  --overwrite        已配置的步骤重新执行并覆盖
  --only a,b         只跑指定步骤（system,install,secrets,hy2,server,harden,porthop）
  --skip a,b         跳过指定步骤
  --yes              全部确认，不再提问
  --dry-run          只打印计划，不执行
  --status           只看状态
  --uninstall        卸载（保留 deploy.env / 证书）
  --purge            卸载并删除 deploy.env / 证书
  --reinstall        卸载并重装（等价 --purge 后全量 --overwrite）
  --rotate-secrets   重建密钥时换掉所有客户端可见的密钥：REALITY 密钥对、
                     short_id 与 HY2 混淆密码。已导出的客户端配置立即失效
                     （默认沿用，交互模式会再确认一次）
  -h, --help         显示本帮助

环境变量（也可直接传给脚本）：
  SSH_PORT  REALITY_DEST  DOMAIN  ENABLE_HY2  SING_BOX_VERSION
  CF_TOKEN  ACME_EMAIL  SERVER_IP  AUTO_DETECT_INTERFACE
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reuse) OPT_REUSE=1 ;;
      --overwrite) OPT_OVERWRITE=1 ;;
      --yes)
        OPT_YES=1
        INTERACTIVE=0
        # 步骤内部也按这个判断要不要提问：只关掉驱动自己的确认不够，
        # secrets / hy2 仍会 read，非交互跑就会卡住或读空
        NONINTERACTIVE=1
        export NONINTERACTIVE
        ;;
      --dry-run) OPT_DRY=1 ;;
      --uninstall) OPT_UNINSTALL=1 ;;
      --purge) PURGE=1 ;;
      --reinstall)
        OPT_REINSTALL=1
        PURGE=1
        ;;
      --rotate-secrets) OPT_ROTATE_SECRETS=1 ;;
      --status)
        OPT_DRY=1
        OPT_YES=1
        OPT_STATUS=1
        ;;
      --only)
        shift
        ONLY="${1:-}"
        ;;
      --only=*) ONLY="${1#*=}" ;;
      --skip)
        shift
        SKIP="${1:-}"
        ;;
      --skip=*) SKIP="${1#*=}" ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "未知参数：$1（--help 看用法）" ;;
    esac
    shift
  done
}

hy2_enabled() { [[ "${ENABLE_HY2:-0}" == "1" ]] || grep -q '^ENABLE_HY2=1' "${ENVFILE}" 2>/dev/null; }

step_title() {
  local v="${1}_TITLE"
  printf '%s' "${!v:-$1}"
}
step_optional() {
  local v="${1}_OPTIONAL"
  printf '%s' "${!v:-0}"
}
step_state() { if "${1}_check" >/dev/null 2>&1; then printf '已配置\n'; else printf '未配置\n'; fi; }

selected() {
  local id="$1"
  if [[ -n "${ONLY}" ]]; then case ",${ONLY}," in *",${id},"*) ;; *) return 1 ;; esac fi
  if [[ -n "${SKIP}" ]]; then case ",${SKIP}," in *",${id},"*) return 1 ;; esac fi
  return 0
}

print_plan() {
  printf '\n%-10s %-8s %-6s %s\n' "步骤" "状态" "可选" "说明"
  printf '%s\n' "--------------------------------------------------------------"
  local id
  for id in "${STEPS[@]}"; do
    selected "${id}" || {
      printf '%-10s %-8s %-6s %s（按参数排除）\n' "${id}" "-" "-" "$(step_title "${id}")"
      continue
    }
    printf '%-10s %-8s %-6s %s\n' "${id}" "$(step_state "${id}")" "$([ "$(step_optional "${id}")" = 1 ] && printf yes || printf no)" "$(step_title "${id}")"
  done
  printf '%s\n\n' "--------------------------------------------------------------"
}

# 返回码：0=覆盖重跑，1=复用，2=跳过
decide() {
  local id="$1" a
  [[ "${OPT_OVERWRITE}" == 1 ]] && return 0
  [[ "${OPT_REUSE}" == 1 ]] && return 1
  [[ "${INTERACTIVE}" == 0 ]] && return 1
  printf '  [%s] 已配置（%s）\n      (r) 复用已存在配置  (o) 覆盖重跑  (s) 跳过   [r] ' "${id}" "$(step_title "${id}")"
  read -r a
  case "${a:-r}" in
    r | R) return 1 ;;
    o | O) return 0 ;;
    *) return 2 ;;
  esac
}

execute() {
  local id="$1"
  log "===== ${id}：$(step_title "${id}") ====="
  if [[ "${OPT_DRY}" == 1 ]]; then
    log "DRY_RUN：跳过执行"
    return 0
  fi
  # 子 shell + errexit：单步失败不会带崩整个流程
  (
    set -eo pipefail
    "${id}_run"
  )
}

# device.sh 与本脚本的相对位置：仓库内它与 deploy.sh 同目录（bin/deploy），一键脚本在
# bin/onekey/，设备脚本在 ../deploy/。找不到就只给文件名，不猜绝对路径。
device_script_path() {
  local dir
  for dir in "${SELF_DIR:-}" "$(cd "$(dirname "$0")" 2>/dev/null && pwd)"; do
    [[ -n "${dir}" ]] || continue
    if [[ -f "${dir}/device.sh" ]]; then
      printf '%s' "${dir}/device.sh"
      return 0
    fi
    if [[ -f "${dir}/../deploy/device.sh" ]]; then
      printf '%s' "$(cd "${dir}/../deploy" && pwd)/device.sh"
      return 0
    fi
  done
  printf 'device.sh'
}

# 已导出的客户端配置是否还对得上服务器的 REALITY 密钥与 HY2 混淆密码。
# 对不上时客户端只会报 reality verification failed，服务端日志是
# REALITY: processed invalid connection，现场很难联想到是 secrets 轮换过密钥。
# 这里在部署结束时主动点出来，而不是等人到客户端上排查。
warn_stale_clients() {
  local dir="${DEPLOY_DIR}/clients" f pub sid obfs stale=()
  command -v jq >/dev/null 2>&1 || return 0
  [[ -d "${dir}" ]] || return 0
  [[ -n "${REALITY_PUBLIC_KEY:-}" ]] || return 0
  for f in "${dir}"/sing-box-client-*.json; do
    [[ -f "${f}" ]] || continue
    read -r pub sid obfs <<<"$(jq -r '[
        ([.outbounds[]? | select(.tls.reality.public_key) | .tls.reality.public_key][0] // ""),
        ([.outbounds[]? | select(.tls.reality.short_id) | .tls.reality.short_id][0] // ""),
        ([.outbounds[]? | select(.type == "hysteria2") | .obfs.password][0] // "")
      ] | @tsv' "${f}" 2>/dev/null | tr '\t' ' ')"
    [[ -n "${pub}" ]] || continue
    if [[ "${pub}" != "${REALITY_PUBLIC_KEY}" || "${sid}" != "${SHORT_ID:-}" ]] \
      || [[ -n "${obfs}" && -n "${OBFS_PASSWORD:-}" && "${obfs}" != "${OBFS_PASSWORD}" ]]; then
      stale+=("$(basename "${f}" .json | sed -E 's/^sing-box-client-//; s/-(desktop|android|ios)$//')")
    fi
  done
  [[ "${#stale[@]}" -gt 0 ]] || return 0
  warn "以下设备的客户端配置与服务器当前密钥不一致，连不上（客户端报 reality verification failed）："
  warn "    $(printf '%s\n' "${stale[@]}" | sort -u | paste -sd' ' -)"
  warn "    重新导出：sudo bash $(device_script_path) export <设备名>"
}

print_next_steps() {
  local dev
  [[ -f "${ENVFILE}" ]] || return 0
  load_env_optional "${ENVFILE}" || true
  dev="$(device_script_path)"
  warn_stale_clients
  printf '\n下一步\n'
  printf '  当前设备：%s\n' "$(device_rows | awk '{print $1}' | paste -sd' ' -)"
  printf '  新增设备：sudo bash %s add <名字> [desktop|android|ios]\n' "${dev}"
  printf '  导出这一台的配置：sudo bash %s export <名字>\n' "${dev}"
  printf '  换凭据：sudo bash %s rotate <名字>　　吊销：sudo bash %s revoke <名字>\n' "${dev}" "${dev}"
  printf '  客户端导入后验收：bash bin/deploy/client/verify.sh\n'
}

# 开局把这次要跑的东西与需要准备的材料讲清楚：缺料在非交互运行下直接退出 2，
# 交互下只提示，真正缺的时候由对应步骤提问。取值来自环境变量与 deploy.env。
preflight() {
  local missing=() want_hy2=0
  [[ "${OPT_STATUS}" == "1" ]] && return 0
  load_env_optional "${ENVFILE}" || true
  # 只在 hy2 确实会执行时要求材料：--skip hy2,porthop 或 ENABLE_HY2=0 都不需要
  if selected hy2 && hy2_enabled; then want_hy2=1; fi

  printf '\n本次需要用到的材料\n'
  printf '  - REALITY_DEST（伪装站点）：%s\n' "${REALITY_DEST:-www.apple.com（默认）}"
  printf '  - DOMAIN（入口域名，启用 Hysteria2 时必填）：%s\n' "${DOMAIN:-未给出}"
  printf '  - Cloudflare API Token（编辑区域 DNS 权限）：%s\n' "$([[ -n "${CF_TOKEN:-}" ]] && printf '已给出' || printf '未给出')"
  printf '  - ACME 邮箱（证书到期通知）：%s\n' "${ACME_EMAIL:-未给出}"
  printf '  - Cloudflare A 记录：域名指向本机，代理关闭（灰云）\n'
  printf '  - 客户端可见密钥（REALITY 密钥对 / short_id / HY2 混淆密码）：%s\n' \
    "$([[ "${OPT_ROTATE_SECRETS}" == "1" ]] && printf '按 --rotate-secrets 换新' || printf '默认沿用已有值，交互时再确认')"
  printf '\n'

  [[ "${want_hy2}" == "1" ]] || return 0
  local k
  for k in DOMAIN CF_TOKEN ACME_EMAIL; do
    if [[ -z "${!k:-}" ]] && ! grep -q "^${k}=." "${ENVFILE}" 2>/dev/null; then
      missing+=("${k}")
    fi
  done
  [[ "${#missing[@]}" -gt 0 ]] || return 0
  warn "启用 Hysteria2 需要的值还没给：${missing[*]}"
  [[ "${INTERACTIVE}" == 1 ]] && return 0
  usage_error "非交互运行缺少 ${missing[*]}；补齐后重跑，或用 --skip hy2,porthop 跳过 Hysteria2"
}

do_install() {
  local id rc run_ok=0 run_fail=0
  local -a todo=()
  for id in "${STEPS[@]}"; do
    selected "${id}" || continue
    if [[ "$(step_state "${id}")" == "已配置" ]]; then
      decide "${id}"
      rc=$?
      case "${rc}" in
        1)
          log "复用 ${id}（不执行）"
          continue
          ;;
        2)
          log "跳过 ${id}"
          continue
          ;;
      esac
    fi
    todo+=("${id}")
  done

  if [[ "${#todo[@]}" -eq 0 ]]; then
    log "没有需要执行的步骤"
    return 0
  fi
  # 可选步骤现在是否启用还不定：ENABLE_HY2 可能要到 secrets 步骤才写进 deploy.env。
  # 计划里用 ? 标出这类步骤，执行前再按 deploy.env 决定跳不跳。
  local -a todo_show=() opt_wait=0
  for id in "${todo[@]}"; do
    if [[ "$(step_optional "${id}")" == 1 ]] && ! hy2_enabled; then
      todo_show+=("${id}?")
      opt_wait=1
    else
      todo_show+=("${id}")
    fi
  done
  log "将执行：${todo_show[*]}"
  [[ "${opt_wait}" == 0 ]] || log "带 ? 的步骤只在 ENABLE_HY2=1 时执行（secrets 步骤里开启也算）"
  if [[ "${INTERACTIVE}" == 1 ]] && [[ "${OPT_DRY}" == 0 ]]; then
    printf '确认开始？[Y/n] '
    local a
    read -r a
    case "${a:-y}" in y | Y) ;; *)
      log "已取消"
      exit 1
      ;;
    esac
  fi
  for id in "${todo[@]}"; do
    # 可选步骤是否执行由 deploy.env 的 ENABLE_HY2 决定，而这份文件可能本轮才被
    # secrets 写入。计划阶段就过滤会把刚开启的 Hysteria2 静默跳过，留到执行前再判。
    if [[ "$(step_optional "${id}")" == 1 ]] && ! hy2_enabled; then
      log "跳过 ${id}（ENABLE_HY2 未开启）"
      continue
    fi
    if execute "${id}"; then run_ok=$((run_ok + 1)); else
      run_fail=$((run_fail + 1))
      warn "步骤 ${id} 失败"
      # 失败后直接给单步重试的命令：改完环境或重传脚本后不用再把 7 步跑一遍
      warn "    单步重试（该步会自动修好目录属主等前置状态）：bash $0 --only ${id} --overwrite --yes"
      if [[ "${INTERACTIVE}" == 1 ]]; then
        printf '继续后面的步骤？[y/N] '
        local a
        read -r a
        case "${a:-n}" in y | Y) ;; *) die "中止：${id} 失败" ;; esac
      else
        die "中止：${id} 失败"
      fi
    fi
  done
  printf '\n完成：%d 个步骤成功，%d 个失败\n' "${run_ok}" "${run_fail}"
  [[ "${run_fail}" -eq 0 ]] || exit 1
  print_next_steps
}

do_uninstall() {
  local id
  load_env_optional "${ENVFILE}" || true
  if [[ "${OPT_DRY}" == 1 ]]; then
    log "DRY_RUN：将卸载 ${STEPS[*]}"
    return 0
  fi
  if [[ "${INTERACTIVE}" == 1 ]] && [[ "${OPT_YES}" == 0 ]]; then
    printf '\n将卸载以下内容：\n  - sing-box 服务与二进制、systemd 单元\n  - ufw 里本项目加的 443/8443-8447 规则、sysctl 优化\n'
    [[ "${PURGE}" == 1 ]] && printf '  - deploy.env / client.env / 证书（--purge）\n'
    printf '确认？[y/N] '
    local a
    read -r a
    case "${a:-n}" in y | Y) ;; *)
      log "已取消"
      return 0
      ;;
    esac
  fi
  for ((i = ${#STEPS[@]} - 1; i >= 0; i--)); do
    id="${STEPS[i]}"
    if "${id}_check" >/dev/null 2>&1; then
      log "卸载 ${id}"
      (
        set -eo pipefail
        "${id}_uninstall"
      ) || warn "${id} 卸载不完整（可手工检查）"
    fi
  done
  if [[ "${PURGE}" == 1 ]]; then
    rm -rf "${DEPLOY_DIR}"
    log "已删除 ${DEPLOY_DIR}"
    rmdir /root/deploy 2>/dev/null || true
  else
    log "保留 ${DEPLOY_DIR}（含密钥与证书，便于下次复用）"
  fi
  log "卸载结束。SSH 防火墙规则、swap、ufw 开关均未改动。"
}

main() {
  trap cleanup_tmp_dirs EXIT
  parse_args "$@"
  local _d="${DOMAIN:-}" _h="${ENABLE_HY2:-}" _r="${REALITY_DEST:-}" _s="${SERVER_IP:-}" _p="${SSH_PORT:-}"
  # shellcheck disable=SC1090  # 路径来自变量，由调用方保证
  [[ -f "${ENVFILE}" ]] && . "${ENVFILE}" 2>/dev/null || true
  [[ -n "${_d}" ]] && DOMAIN="${_d}"
  [[ -n "${_h}" ]] && ENABLE_HY2="${_h}"
  [[ -n "${_r}" ]] && REALITY_DEST="${_r}"
  [[ -n "${_s}" ]] && SERVER_IP="${_s}"
  # 命令行给的 SSH_PORT 优先于 deploy.env；同时标记来源，system 步骤据此区分
  # 「挪端口的过渡放行」与「deploy.env 里的旧值」，后者不放行。
  if [[ -n "${_p}" ]]; then
    SSH_PORT="${_p}"
    SSH_PORT_FROM_ENV=1
    export SSH_PORT_FROM_ENV
  fi

  if [[ "${OPT_REINSTALL}" == 1 ]]; then
    OPT_UNINSTALL=1
    do_uninstall
    OPT_UNINSTALL=0
    OPT_OVERWRITE=1
    OPT_REUSE=0
    log "重新安装：全量覆盖"
  fi

  if [[ "${OPT_UNINSTALL}" == 1 ]]; then
    do_uninstall
    return 0
  fi

  print_plan
  preflight
  # --dry-run 与 --status 的语义都是只看计划，打印完即返回，不进入执行阶段
  [[ "${OPT_DRY}" == 1 ]] && return 0

  [[ "${OPT_DRY}" == 1 ]] || need_root
  if [[ ! -f /etc/debian_version ]]; then
    warn "本脚本只在 Debian / Ubuntu 上验证过，当前系统可能不兼容"
  fi

  [[ -n "${ENABLE_HY2:-}" ]] || ENABLE_HY2=0
  do_install
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
