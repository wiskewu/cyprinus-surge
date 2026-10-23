#!/usr/bin/env bash
# 对仓库内所有 shell 脚本跑 shellcheck，默认严重级，-x 跟进 source 的片段；
# 另查「变量名紧跟多字节字符」这类 bash 3.2 会误解析的写法。
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

# bash 3.2 按字节扫变量名："$code，" 会被当成变量 code\357。
if command -v python3 >/dev/null 2>&1; then
  python3 .build/check-var-braces.py "${files[@]}"
else
  printf '未找到 python3，跳过变量边界检查\n'
fi
