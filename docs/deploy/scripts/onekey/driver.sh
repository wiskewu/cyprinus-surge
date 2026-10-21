# ============================================================================
# 驱动：由 build-onekey.sh 拼接到 deploy.sh 末尾。不要单独执行本文件。
# ============================================================================
OPT_REUSE=0; OPT_OVERWRITE=0; OPT_YES=0; OPT_DRY=0
OPT_UNINSTALL=0; OPT_PURGE=0; OPT_REINSTALL=0
ONLY=""; SKIP=""; INTERACTIVE=1
PURGE=0

usage() {
  cat <<'USAGE'
用法：sudo bash deploy.sh [选项]

不带选项 → 交互模式：先扫描每一步的状态，再逐个询问「复用 / 覆盖 / 跳过」。

  --reuse            已配置的步骤直接复用（不提问）
  --overwrite        已配置的步骤重新执行并覆盖
  --only a,b         只跑指定步骤（system,install,secrets,server,hy2,porthop）
  --skip a,b         跳过指定步骤
  --yes              全部确认，不再提问
  --dry-run          只打印计划，不执行
  --status           只看状态
  --uninstall        卸载（保留 deploy.env / 证书）
  --purge            卸载并删除 deploy.env / 证书
  --reinstall        卸载并重装（等价 --purge 后全量 --overwrite）
  -h, --help         显示本帮助

环境变量（也可直接传给脚本）：
  SSH_PORT  REALITY_DEST  DOMAIN  ENABLE_HY2  SING_BOX_VERSION
  CF_TOKEN  ACME_EMAIL  SERVER_IP  AUTO_DETECT_INTERFACE
USAGE
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --reuse) OPT_REUSE=1 ;;
      --overwrite) OPT_OVERWRITE=1 ;;
      --yes) OPT_YES=1; INTERACTIVE=0 ;;
      --dry-run) OPT_DRY=1 ;;
      --uninstall) OPT_UNINSTALL=1 ;;
      --purge) OPT_PURGE=1; PURGE=1 ;;
      --reinstall) OPT_REINSTALL=1; OPT_PURGE=1; PURGE=1 ;;
      --status) OPT_DRY=1; OPT_YES=1 ;;
      --only) shift; ONLY="${1:-}" ;;
      --only=*) ONLY="${1#*=}" ;;
      --skip) shift; SKIP="${1:-}" ;;
      --skip=*) SKIP="${1#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（--help 看用法）" ;;
    esac
    shift
  done
}

hy2_enabled() { [ "${ENABLE_HY2:-0}" = "1" ] || grep -q '^ENABLE_HY2=1' "$ENVFILE" 2>/dev/null; }

step_title() { local v="${1}_TITLE"; printf '%s' "${!v:-$1}"; }
step_optional() { local v="${1}_OPTIONAL"; printf '%s' "${!v:-0}"; }
step_state() { if "${1}_check" >/dev/null 2>&1; then echo "已配置"; else echo "未配置"; fi; }

selected() {
  local id="$1"
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$id,"*) ;; *) return 1 ;; esac; fi
  if [ -n "$SKIP" ]; then case ",$SKIP," in *",$id,"*) return 1 ;; esac; fi
  return 0
}

print_plan() {
  printf '\n%-10s %-8s %-6s %s\n' "步骤" "状态" "可选" "说明"
  printf '%s\n' "--------------------------------------------------------------"
  local id
  for id in "${STEPS[@]}"; do
    selected "$id" || { printf '%-10s %-8s %-6s %s（按参数排除）\n' "$id" "-" "-" "$(step_title "$id")"; continue; }
    printf '%-10s %-8s %-6s %s\n' "$id" "$(step_state "$id")" "$([ "$(step_optional "$id")" = 1 ] && echo yes || echo no)" "$(step_title "$id")"
  done
  printf '%s\n\n' "--------------------------------------------------------------"
}

# 返回码：0=覆盖重跑，1=复用，2=跳过
decide() {
  local id="$1" a
  [ "$OPT_OVERWRITE" = 1 ] && return 0
  [ "$OPT_REUSE" = 1 ] && return 1
  [ "$INTERACTIVE" = 0 ] && return 1
  printf '  [%s] 已配置（%s）\n      (r) 复用已存在配置  (o) 覆盖重跑  (s) 跳过   [r] ' "$id" "$(step_title "$id")"
  read -r a
  case "${a:-r}" in
    r|R) return 1 ;;
    o|O) return 0 ;;
    *)   return 2 ;;
  esac
}

execute() {
  local id="$1"
  log "===== ${id}：$(step_title "$id") ====="
  if [ "$OPT_DRY" = 1 ]; then
    log "DRY_RUN：跳过执行"
    return 0
  fi
  # 子 shell + errexit：单步失败不会带崩整个流程
  ( set -eo pipefail; "${id}_run" )
}

do_install() {
  local id rc run_ok=0 run_fail=0
  local -a todo=()
  for id in "${STEPS[@]}"; do
    selected "$id" || continue
    if [ "$(step_optional "$id")" = 1 ] && ! hy2_enabled && { [ "$id" = "hy2" ] || [ "$id" = "porthop" ]; }; then
      log "跳过 ${id}（ENABLE_HY2 未开启）"
      continue
    fi
    if [ "$(step_state "$id")" = "已配置" ]; then
      decide "$id"; rc=$?
      case "$rc" in
        1) log "复用 ${id}（不执行）"; continue ;;
        2) log "跳过 $id"; continue ;;
      esac
    fi
    todo+=("$id")
  done

  if [ "${#todo[@]}" -eq 0 ]; then
    log "没有需要执行的步骤"
    return 0
  fi
  log "将执行：${todo[*]}"
  if [ "$INTERACTIVE" = 1 ] && [ "$OPT_DRY" = 0 ]; then
    printf '确认开始？[Y/n] '
    local a; read -r a
    case "${a:-y}" in y|Y) ;; *) log "已取消"; exit 1 ;; esac
  fi
  for id in "${todo[@]}"; do
    if execute "$id"; then run_ok=$((run_ok+1)); else
      run_fail=$((run_fail+1))
      warn "步骤 $id 失败"
      if [ "$INTERACTIVE" = 1 ]; then
        printf '继续后面的步骤？[y/N] '
        local a; read -r a
        case "${a:-n}" in y|Y) ;; *) die "中止：$id 失败" ;; esac
      else
        die "中止：$id 失败"
      fi
    fi
  done
  printf '\n完成：%d 个步骤成功，%d 个失败\n' "$run_ok" "$run_fail"
  [ "$run_fail" -eq 0 ] || exit 1
}

do_uninstall() {
  local id
  load_env "$ENVFILE" 2>/dev/null || true
  if [ "$OPT_DRY" = 1 ]; then
    log "DRY_RUN：将卸载 ${STEPS[*]}"
    return 0
  fi
  if [ "$INTERACTIVE" = 1 ] && [ "$OPT_YES" = 0 ]; then
    printf '\n将卸载以下内容：\n  - sing-box 服务与二进制、systemd 单元\n  - ufw 里本项目加的 443/8443-8447 规则、sysctl 优化\n'
    [ "$PURGE" = 1 ] && printf '  - deploy.env / client.env / 证书（--purge）\n'
    printf '确认？[y/N] '
    local a; read -r a
    case "${a:-n}" in y|Y) ;; *) log "已取消"; return 0 ;; esac
  fi
  for ((i=${#STEPS[@]}-1; i>=0; i--)); do
    id="${STEPS[i]}"
    if "${id}_check" >/dev/null 2>&1; then
      log "卸载 $id"
      ( set -eo pipefail; "${id}_uninstall" ) || warn "$id 卸载不完整（可手工检查）"
    fi
  done
  if [ "$PURGE" = 1 ]; then
    rm -rf "$DEPLOY_DIR"
    log "已删除 $DEPLOY_DIR"
    rmdir /root/deploy 2>/dev/null || true
  else
    log "保留 ${DEPLOY_DIR}（含密钥与证书，便于下次复用）"
  fi
  log "卸载结束。SSH 防火墙规则、swap、ufw 开关均未改动。"
}

main() {
  parse_args "$@"
  local _d="${DOMAIN:-}" _h="${ENABLE_HY2:-}" _r="${REALITY_DEST:-}" _s="${SERVER_IP:-}"
  [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true
  [ -n "$_d" ] && DOMAIN="$_d"
  [ -n "$_h" ] && ENABLE_HY2="$_h"
  [ -n "$_r" ] && REALITY_DEST="$_r"
  [ -n "$_s" ] && SERVER_IP="$_s"

  if [ "$OPT_REINSTALL" = 1 ]; then
    OPT_UNINSTALL=1
    do_uninstall
    OPT_UNINSTALL=0; OPT_OVERWRITE=1; OPT_REUSE=0
    log "重新安装：全量覆盖"
  fi

  if [ "$OPT_UNINSTALL" = 1 ]; then
    do_uninstall
    return 0
  fi

  if [ "$OPT_DRY" = 1 ]; then
    print_plan
    [ "$OPT_YES" = 1 ] && [ "${OPT_PLAN_ONLY:-0}" = "1" ] && return 0
  else
    print_plan
  fi

  [ "$OPT_DRY" = 1 ] || need_root
  if [ ! -f /etc/debian_version ]; then
    warn "本脚本只在 Debian / Ubuntu 上验证过，当前系统可能不兼容"
  fi

  [ -n "${ENABLE_HY2:-}" ] || ENABLE_HY2=0
  do_install
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
