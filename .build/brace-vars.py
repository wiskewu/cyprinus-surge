#!/usr/bin/env python3
"""把 $var 改写成 ${var}，只改真正的展开位置。

要点：
- 引号状态按 `$(` / `(` 的嵌套分层：`"$(grep 'x' "$f")"` 里外层双引号被
  子命令挂起，子命令内部重新起算，用平面状态会逐步漂移
- 单双引号状态跨行传递：多行 awk 程序的闭合引号在下一行行首
- 未引号 heredoc 正文里单双引号是普通字符，照常按展开处理；
  带引号的 heredoc 正文完全不展开，原样保留
- 跳过反斜杠转义的 \\$、行注释、$_ 这个特殊参数

用法：python3 .build/brace-vars.py [--check] file.sh ...
"""

from __future__ import annotations

import re
import sys

NAME = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
SPECIAL = {"_"}


class State:
    def __init__(self) -> None:
        self.stack: list[tuple[bool, bool]] = [(False, False)]

    @property
    def single(self) -> bool:
        return self.stack[-1][0]

    @property
    def double(self) -> bool:
        return self.stack[-1][1]

    def set(self, single: bool, double: bool) -> None:
        self.stack[-1] = (single, double)


def transform(text: str) -> tuple[str, int]:
    out: list[str] = []
    count = 0
    st = State()
    heredoc: str | None = None
    heredoc_quoted = False

    for line in text.splitlines(keepends=True):
        body = line.rstrip("\n")
        tail = line[len(body):]

        if heredoc is not None:
            if body.strip() == heredoc:
                heredoc = None
                out.append(line)
                continue
            if heredoc_quoted:
                out.append(line)
                continue
            new, n, _ = rewrite(body, st, force=True)
            count += n
            out.append(new + tail)
            continue

        new, n, delim = rewrite(body, st)
        count += n
        out.append(new + tail)
        if delim is not None:
            heredoc, heredoc_quoted = delim
    return "".join(out), count


def rewrite(body: str, st: State, force: bool = False) -> tuple[str, int, tuple[str, bool] | None]:
    out: list[str] = []
    i = 0
    count = 0
    heredoc: tuple[str, bool] | None = None

    while i < len(body):
        ch = body[i]

        # 转义：heredoc 里的 \$ 输出字面 $var，两种上下文都跳过
        if ch == "\\" and i + 1 < len(body) and not st.single:
            out.append(body[i:i + 2])
            i += 2
            continue

        if not force:
            if not st.single and not st.double and ch == "#" and (i == 0 or body[i - 1] in " \t;"):
                out.append(body[i:])
                break

            if ch == "'" and not st.double:
                st.set(not st.single, st.double)
                out.append(ch)
                i += 1
                continue

            if ch == '"' and not st.single:
                st.set(st.single, not st.double)
                out.append(ch)
                i += 1
                continue

            if body[i:i + 3] == "<<<":
                out.append("<<<")
                i += 3
                continue

            if body[i:i + 2] == "<<" and not st.single and heredoc is None:
                m = HEREDOC.match(body, i)
                if m:
                    heredoc = (m.group(2), bool(m.group(1)))
                    out.append(m.group(0))
                    i = m.end()
                    continue

            # 子命令与子 shell：引号状态另起一层，闭括号回退。
            # 单引号里的括号是字面量，jq / awk 程序里的 ( ) 不能当嵌套处理，
            # 否则引号状态会错位，把单引号内的 $t 当成 shell 变量改写。
            if body[i:i + 2] == "$(" and not st.single:
                st.stack.append((False, False))
                out.append("$(")
                i += 2
                continue
            if ch == "(" and not st.single and not st.double:
                st.stack.append((False, False))
                out.append(ch)
                i += 1
                continue
            if ch == ")" and not st.single and not st.double and len(st.stack) > 1:
                st.stack.pop()
                out.append(ch)
                i += 1
                continue

        if ch == "$" and not st.single:
            m = NAME.match(body, i)
            if m and m.group(1) not in SPECIAL:
                out.append("${" + m.group(1) + "}")
                i = m.end()
                count += 1
                continue

        out.append(ch)
        i += 1

    return "".join(out), count, heredoc


def main(argv: list[str]) -> int:
    check = "--check" in argv
    files = [a for a in argv if a != "--check"]
    total = 0
    for name in files:
        with open(name, encoding="utf-8") as fh:
            text = fh.read()
        new, n = transform(text)
        total += n
        if n and not check:
            with open(name, "w", encoding="utf-8") as fh:
                fh.write(new)
        if n:
            print(f"{name}: {n}")
    print(f"合计 {total} 处{'（仅统计，未写入）' if check else '，已改写'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
