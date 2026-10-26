# SSH 加固：仅公钥登录

管理入口收敛为一条路径：公钥认证的 SSH。密码登录关闭，root 只接受密钥，端口加速率限制，失败尝试由 fail2ban 封禁。

HTML 版：[docs/quality/index.html](index.html)

## 页面

| 页面 | 内容 |
| --- | --- |
| [index.html](index.html) | 路线选择，为什么不用 SPA |
| [01-client.html](01-client.html) | 客户端密钥、服务器名字、免密登录与旧配置复用 |
| [02-server.html](02-server.html) | 服务端加固与回滚、公钥清点与去重 |
| [03-verify.html](03-verify.html) | 独立验收与排障 |
| [04-reference.html](04-reference.html) | 参数默认值、`ufw limit` 行为、可选双因子 |

## 脚本

| 脚本 | 在哪跑 | 作用 |
| --- | --- | --- |
| `bin/harden/client.sh` | 客户端 | 生成或复用密钥、装公钥、写 `~/.ssh/config`（同地址复用名字与密钥，可改名、可清理旧块）、验证免密 |
| `bin/harden/harden.sh` | 服务器 | 关密码登录、root 仅密钥、限并发、`ufw limit`、fail2ban；`--keys` / `--dedupe` 清点去重公钥 |
| `bin/harden/audit.sh` | 客户端 | 只读验收，全部检查合并为一次远程连接 |
| `bin/lib/ssh-lib.sh` | 被上面三个 source | 端口探测、会话认证判定、sshd 关键字就地改写 |

## 四步

```bash
# 1. 客户端：生成密钥、装公钥、写别名（名字由你定）
bash bin/harden/client.sh --host 203.0.113.10 --port 4061 --alias vps-byte --install-server

# 2. 客户端：确认密钥能登录
ssh -o BatchMode=yes vps-byte true

# 3. 服务器：应用加固
sudo bash bin/harden/harden.sh --whitelist 198.51.100.20

# 4. 客户端：独立验收
bash bin/harden/audit.sh --alias vps-byte
```

第 3 步之前必须完成第 2 步。`bin/harden/harden.sh` 会从 journal 里确认当前会话经公钥认证，读不到证据就拒绝执行。

## 回滚

```bash
sudo bash bin/harden/harden.sh --uninstall
```

删除加固片段，从 `/root/ssh-hardening/latest` 还原被就地改写的文件，恢复 `PasswordAuthentication yes` 与 `ufw allow`。

## 环境说明

脚本不假设端口是 22，一律从 `sshd -T` 读取。只 `reload` 不 `restart`，因此执行期间现有会话不受影响。

`ufw limit` 对同一来源限制 6 次/30 秒，批量脚本与并发终端可能触发，等窗口滑过即恢复。`bin/harden/audit.sh` 为此把远程检查合并成一次连接。
