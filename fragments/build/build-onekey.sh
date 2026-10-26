#!/usr/bin/env bash
# 生成 bin/onekey/deploy-onekey.sh：bin/deploy/lib.sh + bin/deploy/steps/*.sh + fragments/onekey/deploy-driver.sh。
# 改动请改 steps/ 或 onekey/driver.sh，然后重跑本脚本。
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="${OUT:-bin/onekey/deploy-onekey.sh}"
STEPS=()
for f in bin/deploy/steps/*.sh; do
  id="$(basename "${f}" .sh)"
  STEPS+=("${id#*-}") # 10-system → system
done
[[ "${#STEPS[@]}" -gt 0 ]] || {
  printf 'steps/ 为空\n' >&2
  exit 1
}

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# shellcheck disable=SC2034  # 步骤元数据与跨文件变量由间接展开读取'
  printf '%s\n' '# ==========================================================================='
  printf '# deploy.sh，一键脚本。自动生成，勿手改。\n'
  # 不写生成时间：每次构建都改一行会把 diff 弄成噪声，也看不出真正的改动
  printf '%s\n' '#   重新生成：bash fragments/build/build-onekey.sh'
  printf '%s\n' '# ==========================================================================='
  printf '%s\n' 'set -o pipefail'
  printf 'STEPS=(%s)\n' "${STEPS[*]}"
  printf '\n'
  printf '%s\n' '# ---------------------------- lib.sh ----------------------------'
  # 片段的 shebang 与文件级指令由生成器统一给出，拼接时剔除
  sed -e '1{/^#!/d;}' -e '/^# shellcheck shell=bash$/d' -e '/^# shellcheck disable=SC2034/d' bin/deploy/lib.sh
  for f in bin/deploy/steps/*.sh; do
    printf '\n'
    printf '# ---------------------------- %s ----------------------------\n' "$(basename "${f}")"
    sed -e '/^# shellcheck shell=bash$/d' -e '/^# shellcheck disable=SC2034/d' "${f}"
  done
  printf '\n'
  sed -e '/^# shellcheck shell=bash$/d' -e '/^# shellcheck disable=SC2034/d' fragments/onekey/deploy-driver.sh
} >"${OUT}.tmp"

bash -n "${OUT}.tmp" || {
  printf '生成失败：%s 有语法错误\n' "${OUT}.tmp" >&2
  exit 1
}
mv "${OUT}.tmp" "${OUT}"
chmod +x "${OUT}"
printf '已生成 %s，%d 行，%d 个步骤：%s\n' "${OUT}" "$(wc -l <"${OUT}")" "${#STEPS[@]}" "${STEPS[*]}"
