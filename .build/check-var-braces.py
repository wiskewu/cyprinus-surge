#!/usr/bin/env python3
"""检查「变量名紧跟多字节字符」这类 bash 3.2 会误解析的写法。

macOS 自带的 /bin/bash 是 3.2：它按字节扫描变量名，`$code，` 会被解析成
变量 code\\357，set -u 下直接 unbound variable。正确写法是 `${code}，`。
shellcheck 默认严重级不报这一类，所以单独查一遍。

用法：python3 .build/check-var-braces.py file1.sh file2.sh
"""

import pathlib
import re
import sys

BAD = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")


def main(paths: list[str]) -> int:
    hits: list[str] = []
    for name in paths:
        for lineno, line in enumerate(pathlib.Path(name).read_text().splitlines(), 1):
            for m in BAD.finditer(line):
                var = m.group(0)[1:-1]
                hits.append(f"{name}:{lineno}  {m.group(0)}  → 改成 ${{{var}}}")
    for h in hits:
        print(h, file=sys.stderr)
    if hits:
        print(f"变量后紧跟多字节字符 {len(hits)} 处：给变量加大括号", file=sys.stderr)
        return 1
    print(f"变量边界检查通过：{len(paths)} 个文件")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
