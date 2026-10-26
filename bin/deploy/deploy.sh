#!/usr/bin/env bash
# deploy.sh —— 步骤驱动入口。
# 仓库内运行时加载 lib 与 steps 再交给 fragments 里的驱动；上传到服务器时
# 若没有 fragments 目录，直接转到单文件版本 bin/onekey/deploy-onekey.sh。
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRIVER="${SELF_DIR}/../../fragments/onekey/deploy-driver.sh"
if [[ -f "${DRIVER}" ]]; then
  # shellcheck source=SCRIPTDIR/lib.sh
  . "${SELF_DIR}/lib.sh"
  # 步骤表由文件名推导，与一键脚本生成器保持同一套命名规则
  STEPS=()
  for _step in "${SELF_DIR}"/steps/*.sh; do
    STEPS+=("$(basename "${_step}" .sh | sed 's/^[0-9]*-//')")
  done
  for _step in "${SELF_DIR}"/steps/*.sh; do
    # shellcheck source=/dev/null
    . "${_step}"
  done
  unset _step
  # shellcheck source=SCRIPTDIR/../../fragments/onekey/deploy-driver.sh
  . "${DRIVER}"
  main "$@"
else
  ONEKEY="${SELF_DIR}/../onekey/deploy-onekey.sh"
  [[ -f "${ONEKEY}" ]] || {
    printf '[x] 缺少 %s：仓库内运行需要 fragments/，上传运行需要 bin/onekey/\n' "${ONEKEY}" >&2
    exit 2
  }
  exec bash "${ONEKEY}" "$@"
fi
