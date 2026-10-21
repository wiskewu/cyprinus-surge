# SSH 加固：用 SPA 把 22 端口关到不可达

> 让 `sshd` 对整个互联网**不可达**，而不是「藏起来」。配好之后 `ssh server1` 用法不变，敲门发生在 `ProxyCommand` 里。
> 一台设备一把密钥，删一行就是吊销那台。
>
> 参考：[Why I close SSH port 22 entirely](https://www.michelebologna.net/2026/ssh-port-22-fwknop-single-packet-authorization/)（Michele Bologna, 2026-06-11）· [fwknop 官方文档](https://www.cipherdyne.org/fwknop/docs/fwknop-tutorial.html) · [fwknopd(8)](https://manpages.debian.org/unstable/fwknop-server/fwknopd.8.en.html)
>
> HTML 版：[docs/quality/index.html](index.html)

---

## 1. 为什么

免密登录和 SPA 是**叠加的两层**：免密挡「连上了也登不进」，SPA 挡「根本连不上」。先跑[部署手册第 1 步](../deploy/01-init.html)拿掉密码，再用本文挡门。

端口敲击不够——那串端口号是**明文**的，抓下来重放即可，且无认证。SPA 是加密 + HMAC 签名的单个 UDP 包，带时间戳和一次性序列号，重放无效。

关键差别在扫描器看到什么：

```
$ nmap -Pn -p22 203.0.113.10
Not shown: 22/tcp filtered      ← 不是 closed
```

`closed` 是「有东西在监听」，`filtered` 是「静默丢包，什么都没暴露」。端口不是藏在难猜的号码后面，是真的关着。

## 2. 一次访问

```
ssh server1
  → ProxyCommand: fwknop -n server1      发 UDP/62201（加密 + HMAC 签名）
  → sleep 2                              等 fwknopd 把 iptables 规则插进去
  → nc %h %p                             这时 tcp/22 已经对该 IP 放行
```

- `sleep 2` 不能省，它在等规则插入。`>/dev/null 2>&1` 也不能省——`ProxyCommand` 的 stdout 会被 ssh 当成通道读，fwknop 的输出会污染它。
- UDP 可能丢包。`fwknop` 无状态，重复发没有副作用，直接重敲。
- 窗口到期撤的是**新连接**的许可，已建立的会话由连接跟踪维持。长会话要调大 `ACCESS_TIMEOUT`。

配好后的 `~/.ssh/config` 托管块：

```
# BEGIN ssh-spa (managed by 20-client.sh)
Host server1
  HostName 203.0.113.10
  ProxyCommand fwknop -n server1 >/dev/null 2>&1; sleep 2; nc %h %p
# END ssh-spa
```

## 3. 多客户端

| | 每设备独立（推荐） | 全部共用 |
|---|---|---|
| 生成命令 | `--clients "laptop phone"` | `--shared` |
| 吊销一台 | 删一个 stanza，其余不受影响 | **全换**，所有设备重配 |
| 泄露影响面 | 一台 | 所有设备 |

原理：`access.conf` 支持多个 stanza，服务端收到包后**逐个试解密**，只有对上的那个能开规则（`server/incoming_spa.c` 的 `incoming_spa()`）。所以所有 stanza 都写 `SOURCE ANY`——客户端会换 IP，靠地址区分在漫游时直接失效。

密钥包格式（服务端那份**不要发给任何一台客户端**）：

```
SPA_PORT=62201
SSH_PORT=22
ACCESS_TIMEOUT=120
MAX_FW_TIMEOUT=300
HOSTS="server1=203.0.113.10 server2=198.51.100.7"
CLIENTS="laptop=<KEY>:<HMAC> phone=<KEY>:<HMAC>"
```

每台客户端那份把 `CLIENTS` 换成只有自己的一行，并多一行 `CLIENT_NAME`。

> **格式坑：** 每客户端的键值必须写在**一行带引号的 `CLIENTS="..."`** 里。写成 `CLIENT laptop=...` 不是合法 shell 赋值，脚本 source 这个文件时会报 `CLIENT: command not found`。

服务端渲染出的 stanza：

```
SOURCE ANY;
OPEN_PORTS tcp/22;
FW_ACCESS_TIMEOUT 120;      # 规则保留秒数，不设默认 30
MAX_FW_TIMEOUT 300;         # 封顶，客户端 --fw-timeout 也拿不到超过这个值
KEY_BASE64        <该设备的密钥>;
HMAC_KEY_BASE64   <该设备的 HMAC 密钥>;
```

没开 `PERMIT_CLIENT_PORTS`，所以客户端在 `ACCESS` 里写什么都改变不了服务端放行的端口。脚本渲染后会自检：stanza 数必须等于密钥组数。

**吊销**：从密钥包去掉那台，重跑服务端。顺手把设备上那份密钥包删掉——服务端拒绝对它只是「连不上」，本地文件仍是有效凭据。

**轮换**：`--force` 重新生成、分发新包、逐台重跑。两套 stanza 可以共存，能先加新的、确认都迁走了再删旧的。

## 4. 部署

### 第 1 步 · 生成密钥（在你自己安全的机器上）

```bash
bash 00-gen-keys.sh --hosts "server1=203.0.113.10 server2=198.51.100.7" --clients "laptop phone"
```

产出 `spa-keys.env`（服务端，含全部）和 `clients/{laptop,phone}.env`。

### 第 2 步 · 服务端

```bash
scp spa-keys.env root@<服务器>:/root/
ssh root@<服务器> 'bash /root/ssh-spa/10-server.sh --keys /root/spa-keys.env'
```

装 `fwknop-server`、按默认路由网卡渲染 `fwknopd.conf`、从密钥包渲染 `access.conf`、起服务、放行 `62201/udp`。**22 保持原样。**

### 第 3 步 · 客户端（每台各跑一次）

```bash
scp clients/laptop.env <机器>:~/
ssh <机器> 'bash 20-client.sh --keys ~/laptop.env'
```

装 `fwknop`，写 `~/.fwknoprc`，往 `~/.ssh/config` 追加托管块。托管块是幂等的，带 `# BEGIN/END ssh-spa` 标记，重跑只原地替换并清掉多余空行，`--uninstall` 摘掉之后与原文件逐字节一致。

### 第 4 步 · 收口

> **顺序不能反。** 先在**当前 SSH 会话**里另开一个连接确认能进，再做。

```bash
bash /root/ssh-spa/10-server.sh --keys /root/spa-keys.env --close-ssh
```

### 锁门急救

云厂商控制台的 VNC / 串口，或者你之前装了 Tailscale：

```bash
sudo systemctl stop fwknop-server
sudo iptables -D INPUT -j FWKNOP_INPUT
sudo ufw allow 22/tcp
```

或者 `sudo bash 10-server.sh --uninstall`（保留密钥；`--purge` 连密钥一起删）。

## 5. 验收

| # | 检查 | 怎么做 | 通过 |
|---|---|---|---|
| 1 | 敲门有效 | 客户端 `fwknop -n server1`；服务器 `iptables -S FWKNOP_INPUT \| wc -l` | ≥1，超时后变回 0 |
| 2 | 端口不可达 | 另一台外网机器 `nmap -Pn -p22 <IP>` | `filtered`（不是 `closed`） |
| 3 | 用起来无感 | `ssh` / `scp` / `rsync` / VS Code Remote-SSH | 都能直连，不用逐个工具配 |
| 4 | 重放无效 | `tcpreplay -i <iface> /tmp/spa.pcap` | 规则数**不增加** |
| 5 | 单台可吊销 | 从密钥包去掉一台，重跑服务端 | 该设备敲不开，其余照常 |
| 6 | ufw 看不到临时规则 | `ufw status` | 没有 |

第 4 条要先抓包：`sudo tcpdump -i any udp port 62201 -w /tmp/spa.pcap`，再在客户端敲一次。

日常：

```bash
ssh server1                          # 透明
fwknop -n server1                    # 手动敲一次
fwknop -n server1 --fw-timeout 300    # 开窗久一点（被 MAX_FW_TIMEOUT 封顶）
```

值得备份的只有**密钥包**。放密码管理器或 `sops`/`age` 加密的仓库；别进 git，别贴进聊天窗口。

## 6. 排查

| 现象 | 查什么 |
|---|---|
| `ssh` 直接超时 | 服务端 `journalctl -u fwknop-server -n 50`；客户端 `fwknop -n <host> -v`。UDP 被丢了 → 重敲 |
| 敲门后仍连不上 | `iptables -S FWKNOP_INPUT` 看规则插上没有；`iptables -S INPUT \| grep FWKNOP_INPUT` 看跳转还在不在 |
| 客户端报「stanza not found」 | `~/.fwknoprc` 里没有 `[<主机名>]` 段。fwknop 装完会丢一个全注释的同名样例，脚本先备份成 `~/.fwknoprc.bak` |
| 客户端报密钥错误 | 两端密钥对不上。多半是自带样例覆盖了生成的版本 |
| 服务端 fwknopd 起不来 | `fwknopd -F` 前台跑。常见是 `access.conf` 里混进空格或中文标点 |
| 日志里没有 SPA 记录 | 包根本没到。先查云安全组有没有放行 `62201/udp`，再 `tcpdump` |
| `nmap` 显示 22 是 `closed` | 还有别的东西在放行：云安全组、ufw 其他规则 |
| `ssh` 卡在 `kex_exchange_identification` | 你本机的 TUN 把 SSH 也代理了，见下 |

### 与 ufw 的关系

跳转规则插在 `INPUT` 第 1 位，先于 ufw 的链求值，所以 SPA 开的口子不会被挡掉；代价是 `ufw status` 里看不到临时规则。

> **`ufw enable` / `reload` / `reset` 会重建 INPUT 链，冲掉跳转规则，之后 SPA 静默失效**（客户端不报错，SSH 直接超时）。任何 ufw 变更之后 `sudo systemctl restart fwknop-server`。脚本每次改完 ufw 都会自动重启一次。

服务端默认只嗅探 `udp port 62201`。客户端用了 `fwknop --rand-port` 就打不进来，得把 `PCAP_FILTER` 放宽成 `udp dst portrange 10000-65535`——更省事是别用随机端口。

### 本机 TUN 会捕获 SSH 与测速

本机跑着 Clash / sing-box 的 TUN 时，连新服务器的 SSH 也会被隧道接管（新 IP 不在直连规则里）：

```bash
sudo route -n add -host <服务器IP> <局域网网关>    # macOS
sudo ip route add <服务器IP> via <局域网网关>      # Linux
sudo route -n delete -host <服务器IP>             # 用完删掉
```

**本机有 TUN 时，测出来的每个数字都可能是假的**——`nc` / `mtr` / `curl` 都会被送进隧道。验收前先确认测试机器上没有代理客户端在跑。唯一仍可靠的是 `ping`（ICMP 通常不被代理接管）。

### 并行接入通道

```bash
sudo ufw allow in on tailscale0
```

不是「SPA 坏了的备份」，而是**一条独立存在的路**：公网配置写错了，仍能从 tailnet 进去修。VPS 上的 Tailscale 本身也吃 SSH 规则，两件事配套。

### 第二层防火墙

ufw 只是里层，**云厂商安全组是外层，脚本碰不到**。不在外层放行 `62201/udp`，敲门包到不了网卡；SSH 端口则可以在收口验证通过后从安全组删掉。

## 7. 已知限制

- **不是万能。** 挡的是「没密钥的人连不上 sshd」。OpenSSH 自身的 0day 仍要靠及时打补丁；拿到密钥的中间人依然成立。改变的是**暴露窗口**。
- **密钥就是命门。** 泄露 = 22 随时对攻击者开放，且**日志里没有任何异常**——在他看来就是一次合法敲门。
- **需要 UDP 出境。** 部分校园网/公司网封 UDP 时 SPA 反而挡了你的路。
- **服务商可能封 UDP 或非标端口。** 表现和「客户端丢包」一样，先 `tcpdump` 确认包到没到。
- **脚本按 Debian/Ubuntu 写**（apt + ufw + systemd；服务端包 `fwknop-server`、客户端包 `fwknop-client`）。客户端脚本已支持 brew / pacman。

## 8. 文件

```
docs/quality/
  index.html          手册入口（可离线打开）
  README.md           本文
  scripts/
    lib.sh            共用函数
    00-gen-keys.sh    生成密钥包：服务端一份 + 每客户端一份
    10-server.sh      装 fwknopd、渲染配置、改防火墙（--close-ssh / --status / --uninstall / --purge）
    20-client.sh      装 fwknop、写 ~/.fwknoprc 与 ~/.ssh/config 托管块
  diagrams/           三张已校验的图（拓扑 / 访问链路 / 规则生命周期）
```

三个脚本都幂等，改完配置重跑即可。渲染出来的文件都带「勿手改」标记并由脚本覆盖。