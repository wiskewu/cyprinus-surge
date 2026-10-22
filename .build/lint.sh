#!/usr/bin/env bash
# 对仓库内所有 shell 脚本跑 shellcheck，默认严重级，-x 跟进 source 的片段。
# npm run lint 调用本脚本；直接 bash .build/lint.sh 亦可。
set -euo pipefail
cd "$(dirname "$0")/.."

files=()
while IFS= read -r f; do files+=("$f"); done < <(find docs -name '*.sh' | sort)
[[ "${#files[@]}" -gt 0 ]] || { printf '未找到脚本\n' >&2; exit 1; }

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${files[@]}"
else
  npx --yes shellcheck -x "${files[@]}"
fi
printf 'shellcheck 通过：%d 个文件\n' "${#files[@]}"
