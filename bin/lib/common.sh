#!/usr/bin/env bash
# shellcheck disable=SC2034  # UI_CHOICE / UI_ANSWER 供 source 本文件的脚本读取
# 所有脚本共用的基础函数与交互组件。被 bin/ 下的脚本 source，不单独运行，
# 也不修改调用方的 shell 选项。
#
# 退出码约定：0 成功；1 运行失败；2 用法或参数错误。

log() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}
usage_error() {
  printf '\033[31m[x]\033[0m %s\n' "$*" >&2
  exit 2
}

need_root() {
  [[ "${SKIP_ROOT:-0}" == "1" ]] && return 0
  [[ "$(id -u)" == "0" ]] || die "需要 root：sudo bash $0"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1"; }

# ---- 交互组件 ----
# 规则：有 TTY 才提问；没有 TTY 时由调用方给出参数，缺参数即 usage_error。

ui_has_tty() { [[ -t 0 && -t 1 ]]; }

# 需要交互却没有 TTY 时统一口径，便于脚本调用方早失败
ui_require_tty() {
  ui_has_tty && return 0
  usage_error "非交互环境：请显式给出参数（见 --help）"
}

# 单选菜单。参数：标题，之后是 "值|说明" 形式的多项。结果写入 UI_CHOICE。
UI_CHOICE=""
ui_menu() {
  local title="$1"
  shift
  local items=("$@") i ans
  ui_require_tty
  printf '\n%s\n' "${title}" >&2
  for i in "${!items[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${items[i]#*|}" >&2
  done
  printf '  0) 退出\n' >&2
  while :; do
    printf '请选择 [0-%d]：' "${#items[@]}" >&2
    read -r ans || exit 1
    [[ "${ans}" =~ ^[0-9]+$ ]] || {
      warn "请输入序号"
      continue
    }
    [[ "${ans}" == 0 ]] && exit 0
    if ((ans >= 1 && ans <= ${#items[@]})); then
      UI_CHOICE="${items[ans - 1]%%|*}"
      return 0
    fi
    warn "超出范围"
  done
}

# 文本输入，带默认值。结果写入 UI_ANSWER。
UI_ANSWER=""
ui_ask() {
  local prompt="$1" def="${2:-}" ans=""
  ui_require_tty
  if [[ -n "${def}" ]]; then
    printf '%s [%s]：' "${prompt}" "${def}" >&2
  else
    printf '%s：' "${prompt}" >&2
  fi
  read -r ans || exit 1
  UI_ANSWER="${ans:-${def}}"
}

# 是否确认。返回 0 表示 yes。
ui_confirm() {
  local prompt="$1" def="${2:-n}" ans=""
  ui_require_tty
  printf '%s [%s]：' "${prompt}" "${def}" >&2
  read -r ans || exit 1
  ans="${ans:-${def}}"
  case "${ans}" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ---- 临时目录 ----
_TMP_DIRS=()
mktemp_dir() { # $1=变量名
  local d base
  [[ -n "${1:-}" ]] || die "mktemp_dir 需要一个变量名"
  # 每个 shell 一个基准目录，trap 里写死路径：数组可能被重设，值不会
  base="${_TMP_BASE:-}"
  if [[ -z "${base}" ]]; then
    base="$(mktemp -d "${TMPDIR:-/tmp}/cs.XXXXXXXX")"
    _TMP_BASE="${base}"
    # shellcheck disable=SC2064  # 有意在设置时展开：后面重设变量也不影响清理
    trap "rm -rf '${base}'" EXIT
  fi
  d="$(mktemp -d -p "${base}")"
  _TMP_DIRS+=("${d}")
  printf -v "$1" '%s' "${d}"
}
cleanup_tmp_dirs() {
  local d
  for d in ${_TMP_DIRS[@]+"${_TMP_DIRS[@]}"}; do
    [[ -n "${d}" ]] && rm -rf "${d}"
  done
  _TMP_DIRS=()
  return 0
}
