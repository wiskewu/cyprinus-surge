# 待办

本文件记录已知未完成项。完成一项后删掉对应条目，不写完成记录。

## shell 脚本

变量大括号已在 27 个脚本里统一为 `${var}`，`npm run lint` 用
`shellcheck -o require-variable-braces` 长期守住；`echo` 已全部换成
`printf`，含写配置文件时用 `printf '%s\n'` 固定格式。

| # | 事项 | 现状 | 代价 |
| --- | --- | --- | --- |
| 2 | 列表改用数组 | 19 处 `for x in $LIST` 依赖空格分隔字符串 | 涉及端口列表与 `HOSTS`，改动会动到 `ufw`、`iptables`、`fwknop` 的调用签名，须连同验证一起做 |
| 4 | 引入 `shfmt` 统一布局 | 未执行，本机无该工具 | 需先确定缩进与换行风格，再一次性格式化；会与 `build-onekey.sh` 的拼接结果一起变动 |
| 5 | 临时目录清理统一用 `trap EXIT` | 仅 `50-render-client.sh`、`test-ai-exit.sh` 使用 | 其余脚本的 `mktemp -d` 依赖函数返回时清理，异常退出会残留 |

## 真实环境验证

| # | 事项 | 现状 |
| --- | --- | --- |
| 6 | 全部脚本在 Debian 12/13、Ubuntu 22.04/24.04 实机跑通 | 仅在 Windows git-bash 沙箱用替代实现验证：`sshd`、`ufw`、`iptables`、`systemctl` 均为桩程序 |
| 7 | 防火墙与 sshd 的真实返回码 | `ufw --force delete` 删除不存在的规则、`iptables -X` 清理不存在的链、`sshd -t` 失败后的 reload 行为均未验证 |
| 8 | `deploy.sh` 的证书与端口跳跃分支 | ACME DNS-01 签发、Hysteria2 端口跳跃、fail2ban 联动未在真实域名与云账号下验证 |
| 9 | `test-ai-exit.sh` | 需要真实 sing-box 二进制与可用出口，沙箱内未执行 |

## 文档

| # | 事项 | 现状 |
| --- | --- | --- |
| 10 | 全站正文按 humanizer 复查 | 本轮只处理了脚本输出与两处页面措辞，其余正文未系统性检视 |
| 11 | 页面示例输出与脚本实际输出逐条核对 | 只核对了 `03-deploy.html` 的退出章节与参数表 |
| 12 | `deploy.sh` 生成时间戳 | 由 `build-onekey.sh` 写入，每次重算都会产生一次无意义 diff，可考虑改为不写入时间 |
