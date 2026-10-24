#!/usr/bin/env bash
# selfcheck-sing-box.sh —— sing-box 起不来时的现场自检与自动定位。
#
#   sudo bash selfcheck-sing-box.sh            # 只读诊断，打印结论
#   sudo bash selfcheck-sing-box.sh --recover  # 恢复原单元与目录属主并重启
#   sudo bash selfcheck-sing-box.sh --fix-dac  # 只按生效 User 修正 /var/lib/sing-box 属主
#
# 诊断思路：用真实二进制在 systemd-run 里复现，失败时逐组去掉属性做 leave-one-out，
# 直接指出是哪一组属性挡住了启动。所有试验用临时单元，退出时清理。
set -uo pipefail

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

UNIT="/etc/systemd/system/sing-box.service"
UNIT_ORIG="${UNIT}.orig"
MP="sing-box"
RUN_DIR="/var/lib/sing-box"
CONF_DIR="/etc/sing-box"
CONF="${CONF_DIR}/config.json"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
MODE=check

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recover) MODE=recover ;;
    --fix-dac) MODE=fixdac ;;
    -h | --help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

[[ "$(id -u)" == 0 ]] || die "需要 root：sudo bash $0"
command -v systemctl >/dev/null 2>&1 || die "本脚本按 systemd 写"

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn2() { printf '  \033[33m!\033[0m %s\n' "$*"; }
info() { printf '  %-24s %s\n' "$1" "$2"; }

show_prop() { systemctl show -p "$1" --value "${MP}" 2>/dev/null || true; }
unit_get() { grep -oE "^$1=.*" "${UNIT}" 2>/dev/null | cut -d= -f2- || true; }

EFF_USER="$(show_prop User)"
[[ -n "${EFF_USER}" ]] || EFF_USER="$(unit_get User)"
EFF_GROUP="$(show_prop Group)"
[[ -n "${EFF_GROUP}" ]] || EFF_GROUP="$(unit_get Group)"
[[ -n "${EFF_USER}" ]] || EFF_USER=root
[[ -n "${EFF_GROUP}" ]] || EFF_GROUP="$(id -gn "${EFF_USER}" 2>/dev/null || printf 'root')"

TRIAL_UNITS=()
cleanup_units() {
  local u
  for u in ${TRIAL_UNITS[@]+"${TRIAL_UNITS[@]}"}; do
    systemctl stop "${u}" >/dev/null 2>&1 || true
    systemctl reset-failed "${u}" >/dev/null 2>&1 || true
  done
  [[ -n "${SCRATCH:-}" ]] && rm -f "${SCRATCH:-}"
  return 0
}
trap cleanup_units EXIT

# ---------------------------------------------------------------- 恢复模式
restore_dir_for_user() { # $1=目标用户
  local u="$1"
  [[ -d "${RUN_DIR}" ]] || return 0
  chown -R "${u}:$(id -gn "${u}")" "${RUN_DIR}"
  chmod 750 "${RUN_DIR}"
}

case "${MODE}" in
  fixdac)
    log_user="${EFF_USER}"
    restore_dir_for_user "${log_user}"
    ok "${RUN_DIR} 归 ${log_user}:$(id -gn "${log_user}") 750"
    systemctl restart "${MP}"
    sleep 1
    if systemctl is-active --quiet "${MP}"; then
      ok "服务已起来"
    else
      bad "服务仍未起来，跑 bash $0 看诊断"
    fi
    exit 0
    ;;
  recover)
    say "恢复：原单元 + 目录属主"
    systemctl stop "${MP}" >/dev/null 2>&1 || true
    if [[ -f "${UNIT_ORIG}" ]]; then
      cp -a "${UNIT_ORIG}" "${UNIT}"
      ok "已用 ${UNIT_ORIG} 覆盖单元"
    else
      warn2 "没有 ${UNIT_ORIG}，保持现有单元"
    fi
    restore_dir_for_user "$(unit_get User || printf 'root')"
    ok "${RUN_DIR} 属主按单元里的 User 对齐"
    systemctl daemon-reload
    systemctl start "${MP}"
    sleep 1
    if systemctl is-active --quiet "${MP}"; then
      ok "服务已恢复"
      ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ':(443|8443)$' | sed 's/^/      /' || true
      exit 0
    fi
    bad "原单元也没起来，继续做完整诊断"
    MODE=check
    ;;
esac

# ---------------------------------------------------------------- 1 生效配置
say "1/6 生效配置"
info "FragmentPath" "$(show_prop FragmentPath)"
info "DropInPaths" "$(show_prop DropInPaths || printf '无')"
info "单元文件 User=" "$(unit_get User || printf '未设置')"
info "生效 User" "${EFF_USER}"
info "生效 Group" "${EFF_GROUP}"
info "生效 StateDirectory" "$(show_prop StateDirectory || printf '未设置')"
info "生效 ProtectSystem" "$(show_prop ProtectSystem || printf '未设置')"
info "生效 ReadWritePaths" "$(show_prop ReadWritePaths || printf '未设置')"
info "生效 CapabilityBoundingSet" "$(show_prop CapabilityBoundingSet || printf '未设置')"
info "生效 AmbientCapabilities" "$(show_prop AmbientCapabilities || printf '未设置')"
info "生效 SystemCallFilter" "$(show_prop SystemCallFilter || printf '未设置')"
info "备份文件" "$([[ -f "${UNIT_ORIG}" ]] && printf '存在' || printf '无')"
# shellcheck disable=SC1091  # 系统文件，构建机上不存在
info "OS" "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-未知}")"
info "systemd" "$(systemctl --version 2>/dev/null | head -1)"
info "sing-box" "$("${SB_BIN}" version 2>/dev/null | head -1 || printf '取不到')"

DROPINS="$(show_prop DropInPaths)"
if [[ -n "${DROPINS}" ]]; then
  say "1b drop-in 内容"
  local_i=0
  for f in ${DROPINS}; do
    local_i=$((local_i + 1))
    printf '  --- %s ---\n' "${f}"
    sed 's/^/      /' "${f}" 2>/dev/null || printf '      读不到\n'
  done
fi

# ---------------------------------------------------------------- 2 服务与日志
say "2/6 服务状态与最近日志"
info "is-active" "$(systemctl is-active "${MP}" 2>/dev/null || printf '未知')"
systemctl show -p NRestarts -p Result -p ExecMainStatus -p ExecMainCode "${MP}" 2>/dev/null | sed 's/^/  /'
printf '  --- 最近 20 行 ---\n'
journalctl -u "${MP}" -n 20 --no-pager 2>&1 | sed 's/^/  /' || true
printf '  --- 内核拒绝记录 ---\n'
journalctl -k -n 200 --no-pager 2>/dev/null | grep -iE 'apparmor|selinux|denied' | tail -5 | sed 's/^/  /' \
  || printf '  无\n'

# ---------------------------------------------------------------- 3 路径与属主
say "3/6 路径与属主"
info "运行目录" "$(ls -ld "${RUN_DIR}" 2>&1)"
info "private 副本" "$(ls -ld "/var/lib/private/${MP}" 2>&1 || printf '无')"
info "配置目录" "$(ls -ld "${CONF_DIR}" 2>&1)"
find "${CONF_DIR}" -maxdepth 1 -mindepth 1 -printf '  %M %u %g %s %p\n' 2>/dev/null | sort
printf '  --- namei ---\n'
namei -l "${RUN_DIR}" 2>&1 | sed 's/^/  /' || true
info "生效用户" "$(id "${EFF_USER}" 2>&1)"
if command -v lsattr >/dev/null 2>&1; then
  info "属性位" "$(lsattr -d "${RUN_DIR}" 2>&1 || true)"
fi

DIR_OWNER="$(stat -c '%U' "${RUN_DIR}" 2>/dev/null || printf '未知')"
DIR_GROUP="$(stat -c '%G' "${RUN_DIR}" 2>/dev/null || printf '未知')"
DIR_MODE="$(stat -c '%a' "${RUN_DIR}" 2>/dev/null || printf '未知')"

# ---------------------------------------------------------------- 4 以生效用户自检
say "4/6 以 ${EFF_USER} 身份自检"
as_user() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "${EFF_USER}" -- "$@"
  else
    su -s /bin/sh "${EFF_USER}" -c "$(printf '%q ' "$@")"
  fi
}
if as_user test -x "${RUN_DIR}"; then ok "能进入 ${RUN_DIR}"; else bad "进不去 ${RUN_DIR}"; fi
if as_user test -w "${RUN_DIR}"; then ok "能写 ${RUN_DIR}"; else bad "不能写 ${RUN_DIR}"; fi
if as_user test -r "${CONF}"; then ok "能读 ${CONF}"; else bad "读不到 ${CONF}"; fi
if as_user "${SB_BIN}" check -c "${CONF}" >/tmp/sbcheck.$$ 2>&1; then
  ok "sing-box check 通过"
else
  bad "sing-box check 失败"
  sed 's/^/      /' /tmp/sbcheck.$$
fi
rm -f /tmp/sbcheck.$$

# 真实二进制复现：把入站换成一个高位回环端口，不动线上端口，也不需要停服务
# 临时配置放配置目录：/tmp 会被 PrivateTmp 换成空的私有目录，/run 上的文件在不同
# 试验之间会被清理，只有 /etc/sing-box 与线上配置同源、稳定可读
SCRATCH=""
SCRATCH_PORT=""
make_scratch_config() {
  local p="$1"
  if command -v jq >/dev/null 2>&1; then
    jq --argjson p "${p}" \
      '.inbounds = [{type:"mixed", tag:"probe-in", listen:"127.0.0.1", listen_port:$p}]' \
      "${CONF}" >"${SCRATCH}" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "${CONF}" "${SCRATCH}" "${p}" <<'PY'
import json, sys
src, dst, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(src))
d["inbounds"] = [{"type": "mixed", "tag": "probe-in", "listen": "127.0.0.1", "listen_port": port}]
json.dump(d, open(dst, "w"), ensure_ascii=False)
PY
  else
    return 1
  fi
  [[ -s "${SCRATCH}" ]] || return 1
  chown "root:${EFF_GROUP}" "${SCRATCH}" 2>/dev/null || true
  chmod 640 "${SCRATCH}" 2>/dev/null || true
  return 0
}
SCRATCH="${CONF_DIR}/.probe-config.json"
for SCRATCH_PORT in 18080 18081 18181 18282 18383; do
  if as_user "${SB_BIN}" check -c "${CONF}" >/dev/null 2>&1 && make_scratch_config "${SCRATCH_PORT}"; then
    break
  fi
done
if [[ -s "${SCRATCH}" ]]; then
  # 不用 set +e / set -e 切换：那会把 errexit 永久打开，后面的试验第一次失败就整个退出
  if timeout 3 runuser -u "${EFF_USER}" -- "${SB_BIN}" run -D "${RUN_DIR}" -c "${SCRATCH}" \
    >/tmp/sbrun.$$ 2>&1; then
    run_rc=0
  else
    run_rc=$?
  fi
  if [[ "${run_rc}" == 124 ]]; then
    ok "以 ${EFF_USER} 直接运行可用（跑满 3 秒被 timeout 收掉）"
  else
    bad "以 ${EFF_USER} 直接运行失败（退出码 ${run_rc}）"
    sed 's/^/      /' /tmp/sbrun.$$ | head -3
  fi
  rm -f /tmp/sbrun.$$
else
  warn2 "没有 jq 与 python3，跳过真实二进制复现"
fi

# ---------------------------------------------------------------- 5 沙箱分组试验
say "5/6 systemd 沙箱分组试验（/bin/sh 探针）"
N=0
trial_sh() {
  local name="$1"
  shift
  local unit
  N=$((N + 1))
  unit="sbprobe-$$-${N}"
  TRIAL_UNITS+=("${unit}")
  if systemd-run --quiet --unit="${unit}" --wait --pipe "$@" \
    /bin/sh -c "cd ${RUN_DIR} && : > .probe && rm -f .probe" >/dev/null 2>&1; then
    ok "${name}"
    return 0
  fi
  bad "${name}"
  journalctl -u "${unit}" -n 3 --no-pager 2>&1 | sed 's/^/      /' || true
  return 1
}
USERP=("--property=User=${EFF_USER}" "--property=Group=${EFF_GROUP}")
trial_sh "基线：不设任何属性"
trial_sh "身份：User/Group" "${USERP[@]}"
trial_sh "身份 + StateDirectory" "${USERP[@]}" --property="StateDirectory=${MP}" --property="StateDirectoryMode=0750"
trial_sh "文件系统组" "${USERP[@]}" --property="ProtectSystem=strict" --property="ProtectHome=yes" \
  --property="PrivateTmp=yes" --property="ReadWritePaths=${RUN_DIR}"
trial_sh "内核面组" "${USERP[@]}" --property="ProtectSystem=strict" \
  --property="ReadWritePaths=${RUN_DIR}" \
  --property="ProtectKernelTunables=yes" --property="ProtectKernelModules=yes" \
  --property="ProtectKernelLogs=yes" --property="ProtectControlGroups=yes" \
  --property="ProtectClock=yes" --property="ProtectHostname=yes" --property="ProtectProc=invisible"
trial_sh "能力组" "${USERP[@]}" \
  --property="CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW" \
  --property="AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW"
trial_sh "进程面组" "${USERP[@]}" --property="NoNewPrivileges=yes" --property="RestrictNamespaces=yes" \
  --property="LockPersonality=yes" --property="MemoryDenyWriteExecute=yes" \
  --property="SystemCallArchitectures=native" --property="SystemCallFilter=@system-service" \
  --property="SystemCallErrorNumber=EPERM"

# ---------------------------------------------------------------- 6 真实二进制 + 完整沙箱
say "6/6 真实二进制 + 完整沙箱（逐组排除）"
GROUPS=()
G_ID=("StateDirectory=${MP}" "StateDirectoryMode=0750")
G_FS=("ProtectSystem=strict" "ProtectHome=yes" "PrivateTmp=yes" "ReadWritePaths=${RUN_DIR}")
G_KERNEL=("ProtectKernelTunables=yes" "ProtectKernelModules=yes" "ProtectKernelLogs=yes"
  "ProtectControlGroups=yes" "ProtectClock=yes" "ProtectHostname=yes" "ProtectProc=invisible")
G_CAP=("CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW"
  "AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW")
G_PROC=("NoNewPrivileges=yes" "RestrictNamespaces=yes" "LockPersonality=yes"
  "MemoryDenyWriteExecute=yes" "SystemCallArchitectures=native"
  "SystemCallFilter=@system-service" "SystemCallErrorNumber=EPERM")

trial_bin() { # $1=名称，其余是 "Key=Value" 属性
  local name="$1"
  shift
  local unit args=()
  N=$((N + 1))
  unit="sbbin-$$-${N}"
  TRIAL_UNITS+=("${unit}")
  args+=("--property=User=${EFF_USER}" "--property=Group=${EFF_GROUP}")
  local_port=$((18080 + N))
  local kv
  for kv in "$@"; do args+=("--property=${kv}"); done
  if [[ ! -s "${SCRATCH}" ]]; then
    warn2 "${name}（跳过：没有可用的临时配置）"
    return 2
  fi
  # 用 timeout 跑 4 秒：超时被杀说明它起来了，退出码 1 说明启动即失败
  make_scratch_config "${local_port}" >/dev/null 2>&1 || true
  # timeout 用 124 表示「跑满时长被杀」，那说明服务已经起来；不能把 124 当失败。
  # 注意别写成 if ...; fi 之后再取 $?，那里拿到的是 if 复合命令的状态（0）。
  systemd-run --quiet --unit="${unit}" --wait --pipe "${args[@]}" \
    /usr/bin/timeout 4 "${SB_BIN}" run -D "${RUN_DIR}" -c "${SCRATCH}" >/tmp/sbbin.$$ 2>&1
  rc=$?
  if [[ "${rc}" == 0 || "${rc}" == 124 ]]; then
    ok "${name}"
    rm -f /tmp/sbbin.$$
    return 0
  fi
  bad "${name}（退出码 ${rc}）"
  journalctl -u "${unit}" -n 4 --no-pager 2>/dev/null | grep -iE 'FATAL|denied|status=' \
    | head -2 | sed 's/^/      /' || true
  rm -f /tmp/sbbin.$$
  return 1
}

ALL=("${G_ID[@]}" "${G_FS[@]}" "${G_KERNEL[@]}" "${G_CAP[@]}" "${G_PROC[@]}")
trial_bin "身份组" "${G_ID[@]}"
FULL_RC=0
trial_bin "完整沙箱" "${ALL[@]}" || FULL_RC=1

CULPRIT=""
if [[ "${FULL_RC}" != 0 ]]; then
  for name in ID FS KERNEL CAP PROC; do
    case "${name}" in
      ID) drop=("${G_ID[@]}") ;;
      FS) drop=("${G_FS[@]}") ;;
      KERNEL) drop=("${G_KERNEL[@]}") ;;
      CAP) drop=("${G_CAP[@]}") ;;
      PROC) drop=("${G_PROC[@]}") ;;
    esac
    subset=()
    for kv in "${ALL[@]}"; do
      keep=1
      for d in "${drop[@]}"; do
        [[ "${kv}" == "${d}" ]] && keep=0
      done
      [[ "${keep}" == 1 ]] && subset+=("${kv}")
    done
    if trial_bin "去掉 ${name} 组" "${subset[@]}"; then
      CULPRIT="${name}"
      break
    fi
  done
fi

# ---------------------------------------------------------------- 结论
say "结论"
if [[ "${EFF_USER}" != "$(unit_get User || printf 'root')" ]]; then
  warn2 "生效 User（${EFF_USER}）与单元文件里的值不同，存在 drop-in 覆盖：${DROPINS:-未知}"
fi
if [[ -d "${RUN_DIR}" ]] && [[ "${DIR_OWNER}" != "${EFF_USER}" ]]; then
  if [[ "${EFF_USER}" == "root" ]]; then
    warn2 "服务以 root 运行，但目录属主是 ${DIR_OWNER}:${DIR_GROUP} ${DIR_MODE}；单元的能力集没有 CAP_DAC_OVERRIDE 时 root 不绕过权限"
    printf '      修：chown -R root:root %s && chmod 700 %s\n' "${RUN_DIR}" "${RUN_DIR}"
  else
    warn2 "服务以 ${EFF_USER} 运行，但目录属主是 ${DIR_OWNER}:${DIR_GROUP} ${DIR_MODE}"
    printf '      修：bash %s --fix-dac\n' "$0"
  fi
else
  ok "目录属主与生效用户一致：${DIR_OWNER}:${DIR_GROUP} ${DIR_MODE}"
fi
if [[ -n "${CULPRIT}" ]]; then
  warn2 "完整沙箱失败，去掉 ${CULPRIT} 组后可用：在单元里删掉该组属性，或用 09-harden.sh --minimal"
elif [[ "${FULL_RC}" == 0 ]]; then
  ok "完整沙箱下真实二进制可启动，问题不在沙箱本身"
fi
printf '\n  下一步：\n'
printf '    修目录属主    bash %s --fix-dac\n' "$0"
printf '    回到原单元    bash %s --recover\n' "$0"
printf '    重新加固      bash 09-harden.sh\n'
