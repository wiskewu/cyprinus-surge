#!/usr/bin/env bash
# bin/deploy/share.sh —— 只读：打印某台设备的分享链接。
#
# 与 device.sh export 产出的 JSON 使用同一份凭据与同一份 deploy.env 参数，
# 供只认 URI 的客户端使用（v2rayN、mihomo、手机 App）。
#
# 用法：
#   sudo bash bin/deploy/share.sh laptop
#   sudo bash bin/deploy/share.sh --all
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "${SELF_DIR}/lib.sh"

usage() {
  cat <<'EOF'
用法：sudo bash bin/deploy/share.sh <设备名> | --all

  <设备名>   打印这一台的 vless 与 hy2 链接（hy2 仅在启用时输出）
  --all      打印名单里所有设备的链接
  -h,--help  显示本帮助

只读：不改动配置、不重启服务。参数来自 /etc/sing-box/deploy.env，
凭据来自 devices.list，与 device.sh export 生成的 JSON 完全同源。
EOF
}

show_one() {
  local name="$1" cred
  device_exists "${name}" || die "设备名单里没有 ${name}"
  cred="$(device_get "${name}" | awk '{print $1}')"
  printf '# %s\n' "${name}"
  uri_list "${name}"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

need_root
# 链接参数全部来自 deploy.env：缺文件就没法生成
load_env "${ENVFILE}"

case "${1:-}" in
  --all)
    count=0
    while read -r name _rest; do
      [[ -n "${name}" ]] || continue
      [[ "${count}" -eq 0 ]] || printf '\n'
      show_one "${name}"
      count=$((count + 1))
    done < <(device_rows)
    [[ "${count}" -gt 0 ]] || die "设备名单为空：${DEVICES_LIST}"
    ;;
  "")
    usage
    exit 2
    ;;
  -*)
    usage_error "未知参数：$1"
    ;;
  *)
    show_one "$1"
    ;;
esac

printf '\n以上链接与同设备的 JSON 等价，任选其一导入。\n' >&2
