# SSH 加固：用 fwknop 把 22 端口彻底关掉（支持多台客户端）

> 面向单人自用的 VPS：让 `sshd` 对整个互联网**不可达**，而不是「藏起来」。
> 配好之后 `ssh server1` 的用法完全不变，敲门发生在 `ProxyCommand` 里，你感知不到。
>
> 参考：[Why I close SSH port 22 entirely](https://www.michelebologna.net/2026/ssh-port-22-fwknop-single-packet-authorization/)（Michele Bologna, 2026-06-11）· [fwknop 官方文档](https://www.cipherdyne.org/fwknop/docs/fwknop-tutorial.html) · [access.conf(5)](https://manpages.debian.org/unstable/fwknop-server/fwknopd.8.en.html)

---

## 1. 为什么「只开密钥登录 + fail2ban」还不够

这两样值得做，本方案也假设你已经做了。但它们改变的是**认证之后**的事：

| 已经做到的 | 仍然是暴露的 |
|---|---|
| `PasswordAuthentication no`，爆破无意义 | 22 端口对全互联网开放，任何扫描器都能连上并拿到 banner 和版本号 |
| fail2ban 封掉来源 IP | OpenSSH 一旦出 0day，暴露窗口从「爆破」变成「直接打 daemon」 |
| 日志里失败尝试被静音 | 日志里**仍然每天堆着**连接尝试——因为确实有人在连 |

原文那句话说得准：SPA 不是「换个端口号」这种遮蔽，**22 端口是真的关着**，nmap 看到的是 `filtered`，不是 `closed`。

## 2. SPA 是什么，以及端口敲击为什么不够

**端口敲击（port knocking）**：按顺序连 7000 → 8000 → 9000，服务端识别到序列就临时开 22。
致命伤：序列是**明文**的。任何能看到你流量的人抓下来重放即可，而且没有任何认证——只有「藏」。

**单包授权（Single Packet Authorization, SPA）**：客户端发**一个 UDP 包**，内容用共享密钥加密并用独立 HMAC 密钥签名。`fwknopd` 抓到包后解密、验签，通过才插一条 iptables 规则，只对**你的来源 IP** 开 22，几秒后自动撤掉。

重放也拦得住：包里带时间戳和一次性序列号，`fwknopd` 两样都查，任一不符就静默丢弃。

一次访问的完整链路：

```
你                          互联网                     服务器
 │  fwknop -n server1        │                          │
 │ ──── UDP/62201（加密+HMAC）───►│ ───────────────────────►│ fwknopd 被动嗅探
 │                            │                          │ 验签通过
 │                            │                    iptables 插入：对 <你的IP> 开 tcp/22
 │  ssh server1               │                          │
 │ ──── TCP/22 ─────────────► │ ───────────────────────►│ 握手、认证、登录
 │                            │      120 秒后规则自动消失  │
 │                            │      （已建立的连接不受影响）│
```

UDP 可能丢包。`fwknop` 是无状态的，SSH 卡住就再敲一次，不用等。

## 3. 多台客户端：密钥怎么分

这是本文的重点，也是原文只带过一句的地方（原文用一组共享密钥）。

`access.conf` 支持**多个 stanza**，每个 stanza 有自己的密钥。`fwknopd` 收到包后会**逐个 stanza 试解密**，只有对上的那个能开规则（见 `server/incoming_spa.c` 里 `incoming_spa()` 的 `while(acc)` 循环：任何一步失败都 `acc = acc->next` 继续）。所以所有 stanza 都可以写 `SOURCE ANY`，靠**密钥**区分客户端。

于是有两种模式：

| 模式 | access.conf | 优点 | 代价 |
|---|---|---|---|
| **每客户端独立密钥**（默认） | 每台设备一个 stanza | **丢一台可以单独吊销**，别的设备不受影响 | 密钥分发稍麻烦（脚本已经替你做了） |
| 全部共用一组 | 只有一个 stanza | 轮换时只改一处 | 吊销任何一台 = 全换，所有设备一起重配 |

`00-gen-keys.sh` 两种都支持。默认推荐独立密钥：**丢手机和吊销一台电脑的差别，就是多跑一次脚本和重装一台客户端配置的差别。**

密钥包长这样（注意每客户端的键值放在一行 `CLIENTS="..."` 里——写成 `CLIENT name=…` 的话 shell source 不了）：

```
SPA_PORT=62201
SSH_PORT=22
ACCESS_TIMEOUT=120
MAX_FW_TIMEOUT=300
HOSTS="server1=203.0.113.10 server2=198.51.100.7"
CLIENTS="laptop=<KEY_BASE64>:<HMAC_KEY_BASE64> phone=<KEY_BASE64>:<HMAC_KEY_BASE64>"
```

脚本会产出两份：`spa-keys.env`（服务端，含全部）和 `clients/<名字>.env`（每台机器只有自己的那一份）。**不要把所有客户端的包发到每一台机器上。**

## 4. 避免把自己锁在门外

收掉公网 SSH 规则是有可能把自己关在门外的。所以脚本默认**不关**：

```
10-server.sh            # 装好、开好 SPA 端口，22 仍然开着
  ↓ 在当前 SSH 会话里另开一个连接，确认能进
10-server.sh --close-ssh   # 这才关
```

`10-server.sh` 在关之前会检查 `fwknopd` 真的起来了、`FWKNOP_INPUT` 跳转规则真的插上了；起不来就直接退出并打日志，**此时防火墙还没动**。

万一还是锁了（云厂商控制台的 VNC / 串口，或者先装好的 Tailscale——见第 9 节）：

```bash
sudo systemctl stop fwknop-server
sudo iptables -D INPUT -j FWKNOP_INPUT
sudo ufw allow 22/tcp
```

或者直接跑 `sudo bash 10-server.sh --uninstall`（保留密钥，`--purge` 连密钥一起删）。

## 5. 部署

三个脚本，彼此独立，可以分别在不同机器上跑。

```bash
scp -r docs/quality/scripts root@<服务器>:/root/ssh-spa     # 或者只 scp 你要用的那一个
```

### 5.1 生成密钥（在你自己安全的机器上，不要在服务器上生成）

```bash
bash 00-gen-keys.sh --hosts "server1=203.0.113.10 server2=198.51.100.7" --clients "laptop phone"
```

产出 `spa-keys.env` + `clients/{laptop,phone}.env`。想用共用密钥就 `--shared`。
密钥用 `openssl rand -base64 32` 生成（32 字节随机值，base64 后 44 字符），格式与 `fwknop --key-gen` 相同——fwknop 会自己 base64 解码再派生，任何长度的 base64 字符串都合法。想用 fwknop 自己的生成器也可以，手工跑 `fwknop --key-gen` 把两行贴进去即可。

### 5.2 服务端

```bash
scp spa-keys.env root@<服务器>:/root/
ssh root@<服务器> 'bash /root/ssh-spa/10-server.sh --keys /root/spa-keys.env'
```

做了：`apt install fwknop-server`；按默认路由网卡渲染 `/etc/fwknop/fwknopd.conf`；从密钥包渲染 `/etc/fwknop/access.conf`（0600）；起 `fwknop-server`；`ufw allow 62201/udp`；自检 stanza 数量和密钥数量对得上。

### 5.3 客户端（每台机器各跑一次）

```bash
scp clients/laptop.env <你的机器>:~/
ssh <你的机器> 'bash 20-client.sh --keys ~/laptop.env'
```

做了：装 `fwknop`（Debian/Ubuntu 上包名是 `fwknop-client`，服务端才是 `fwknop-server`）；写 `~/.fwknoprc`（0600，每个主机一个 stanza）；往 `~/.ssh/config` 追加一个**托管块**（`# BEGIN ssh-spa` … `# END ssh-spa`，重跑只会原地替换，不会越堆越多）。

生成的 `~/.fwknoprc`：

```
[default]
SPA_SERVER_PROTO  udp
USE_HMAC          Y
HMAC_DIGEST_TYPE  SHA512
ALLOW_IP          resolve
ACCESS            tcp/22
KEY_BASE64        <这台设备的加密密钥>
HMAC_KEY_BASE64   <这台设备的 HMAC 密钥>

[server1]
SPA_SERVER        203.0.113.10
SPA_SERVER_PORT   62201
```

`~/.ssh/config` 里的托管块：

```
# BEGIN ssh-spa (managed by 20-client.sh)
Host server1
  HostName 203.0.113.10
  ProxyCommand fwknop -n server1 >/dev/null 2>&1; sleep 2; nc %h %p
# END ssh-spa
```

`>/dev/null 2>&1` 是必要的：`ProxyCommand` 的 stdout 会被 ssh 当成加密通道来读，`fwknop` 的任何输出都会污染这条流。
用 `;` 而不是 `&&` 连接：新机器上 `fwknop` 还没装时，敲门失败但 `nc` 照样往下走——那时 22 还开着，正好用同一条命令兼容「装之前」和「装之后」两种状态。

### 5.4 收口

客户端确认能连进来之后：

```bash
bash /root/ssh-spa/10-server.sh --keys /root/spa-keys.env --close-ssh
```

## 6. 验收

| # | 检查 | 通过标准 |
|---|---|---|
| 1 | 敲门有效 | 敲完立刻在**服务器**上 `iptables -S FWKNOP_INPUT \| wc -l` ≥1；`ACCESS_TIMEOUT` 秒后自己变回 0 |
| 2 | 端口对外不可达 | 从**另一台外网机器**：`nmap -Pn -p22 <服务器IP>` → `filtered` |
| 3 | 用起来无感 | `ssh server1` 直接进；`scp`、`rsync`、`sftp`、VS Code Remote-SSH 都走同一条 ProxyCommand，不用单独配置 |
| 4 | 重放无效 | `tcpdump -i any udp port 62201 -w /tmp/x.pcap` 抓一个包，原样重放（`tcpreplay -i <iface> /tmp/x.pcap`），规则数不应增加 |
| 5 | 单台可吊销 | 从 `spa-keys.env` 去掉一台，重跑服务端，该设备立刻敲不开；其余设备不受影响 |
| 6 | 不依赖 nmap 可见性 | `ufw status` 里看不到 SPA 临时规则（fwknopd 直接动 iptables，不经过 ufw） |

`10-server.sh --status` / `20-client.sh --status` 打印当前状态。

## 7. 日常使用

```bash
ssh server1                       # 透明，不用管敲门
fwknop -n server1                 # 手动敲一次（调防火墙时有用）
fwknop -n server1 --fw-timeout 300   # 手动开门久一点（默认被服务端 MAX_FW_TIMEOUT=300 封顶）
```

客户端请求的开窗时长**不能超过**服务端的 `MAX_FW_TIMEOUT`。默认 120 秒够一次交互式登录；如果要跑长时间的 `ssh -t` 会话，把 `ACCESS_TIMEOUT` 调大后重跑服务端脚本。

## 8. 密钥轮换与吊销

```bash
# 吊销一台：改 spa-keys.env 去掉那台（或重跑 00-gen-keys.sh --clients 只留其余的 --force）
bash 10-server.sh --keys spa-keys.env     # 重渲染 access.conf 并重启 fwknopd

# 全换：00-gen-keys.sh --force 重新生成，把服务端包和每个客户端包重新分发
```

轮换期间两套 stanza 可以共存（重新生成时保留旧客户端条目，再分批发），先加新的、确认都迁走了再删旧的。

密钥包是 `chmod 600` 的普通文本，**别进 git、别贴进聊天窗口**。放密码管理器或 `sops`/`age` 加密的仓库。

## 9. 与防火墙、网络的相互作用

**fwknopd 和 ufw 的关系**：fwknopd 自己往 `FWKNOP_INPUT` 链插规则，跳转规则插在 `INPUT` 的**第 1 位**（`IPT_INPUT_ACCESS` 的默认值 `ACCEPT, filter, INPUT, 1, FWKNOP_INPUT, 1`），所以在 ufw 的链**之前**求值——SPA 开的口子不会被 ufw 的规则挡掉。代价是 `ufw status` 里看不到这些临时规则（它不知道 fwknopd 存在）。

**坑：`ufw enable` / `ufw reload` / `ufw reset` 会重建 INPUT 链，把跳转规则冲掉。**之后 SPA 静默失效（`fwknop` 客户端不报错，SSH 直接超时）。任何 ufw 变更之后：

```bash
sudo systemctl restart fwknop-server     # 让它把跳转插回去
```

`10-server.sh` 每次改完 ufw 都会自动重启一次。

**注意 `PCAP_FILTER`**：服务端默认只嗅探 `udp port 62201`。客户端用了 `fwknop --rand-port` 就打不进来，得把服务端这一行放宽成 `udp dst portrange 10000-65535`。

**并行接入通道**：建议在同网（如 Tailscale / WireGuard 的 `tailscale0`）上再留一条不经敲门的路，并让 ufw 放行该接口：

```bash
sudo ufw allow in on tailscale0
```

它的作用不是「fwknop 坏了的备份」，而是**一条独立存在的路**：公网配置写错了，你仍然能从 tailnet 进去修。

## 10. 批量管理（Ansible）

单机脚本手动跑没问题；机器多了就把敲门接进 SSH 客户端本身：

```yaml
# group_vars/all/vars.yml
ansible_ssh_common_args: >-
  -o ProxyCommand="sh -c 'fwknop -n {{ inventory_hostname }} >/dev/null 2>&1; sleep 2; exec nc %h %p'"
```

用 `inventory_hostname` 而不是 `%h`：`%h` 是 `ansible_host` 解析出来的值（可能是 IP），而 `~/.fwknoprc` 里的 stanza 是按 inventory 主机名命名的。新机器还没装 fwknop 时敲门会失败，但 `nc` 会直连（那时 22 还开着），所以同一条配置在安装前后都成立。配 `ControlPersist` 后每次 play 只敲一次，不是每个 task 都敲。

原文提到过一个真实的坑，值得记住：两个角色一个负责「加公网 SSH 规则」、一个负责「删」，互相覆盖，结果谁最后跑谁说了算，每次 Ansible 都绿但端口又开了。**根治办法不是调 role 顺序，是让两边的同一个变量表达同一件事**——谁最后跑结果都一样：

```yaml
# base role 的默认值
ssh_public: "{{ not (fwknop_enabled | default(false) | bool) }}"
```

## 11. 故障排查

| 现象 | 查什么 |
|---|---|
| `ssh` 直接超时 | 服务端 `journalctl -u fwknop-server -n 50`。客户端 `fwknop -n <host> -v`（会打印它发到哪儿）。UDP 被中间设备丢了 → 重敲一次 |
| 敲门后仍连不上 | 服务端 `iptables -S FWKNOP_INPUT` 看规则有没有插上；`iptables -S INPUT \| grep FWKNOP_INPUT` 看跳转还在不在（多半是 ufw reload 过） |
| 客户端报「stanza not found」 | `~/.fwknoprc` 里没有 `[<主机名>]` 段。fwknop 装完会丢一个全注释的同名样例文件，脚本会先备份成 `~/.fwknoprc.bak` |
| 客户端报密钥相关错误 | 服务端和客户端的密钥对不上。多半是客户端装 fwknop 时自带的样例 `~/.fwknoprc` 覆盖了生成的版本 |
| 服务端 fwknopd 起不来 | `fwknopd -F` 前台跑看报错。常见是 `access.conf` 里混进了空格或中文标点 |
| `nmap` 显示 22 是 `closed` 而不是 `filtered` | 还有别的东西在放行 22（云厂商的安全组、`ufw` 的其他规则） |
| Docker 改了 iptables 导致 SPA 失效 | Docker 重写 FORWARD/nat 链时可能影响跳转。用 `IPT_INPUT_ACCESS` 的位置参数兜底，或把 fwknopd 的跳转移到自己的链里手工维护 |

## 12. 已知限制

- **不是万能**。SPA 挡的是「没钥匙的人连不上 sshd」。服务器自身的 OpenSSH 0day 依然要靠及时打补丁；拿到密钥的中间人攻击也依然成立。原文说得对：SPA 改变的是**暴露窗口**，不是消灭漏洞。
- **密钥就是命门**。密钥泄露 = 22 端口随时对攻击者开放，且不会有任何日志异常（在他看来就是一次合法敲门）。
- **需要 UDP 出境**。SPA 走 UDP。对 UDP 严格管控的网络（部分校园网/公司网）里 62201/udp 可能不通，这时 SPA 反而挡了你的路——那种环境本来就该走别的路。
- **服务商可能封 UDP/非标端口**，被封了的表现和「客户端丢包」一模一样，先在服务端 `tcpdump -i any udp port 62201` 确认包到没到。
- **`ALLOW_IP resolve` 需要能访问外网**（fwknop 查公网 IP 的服务）。固定 IP 的机器可以在 `~/.fwknoprc` 里直接写死 `ALLOW_IP <你的IP>`。
- **本文脚本按 Debian/Ubuntu 写**（`apt` + `ufw` + systemd，服务端包 `fwknop-server`、客户端包 `fwknop-client`）。其他发行版照着改；客户端脚本已额外支持 brew / pacman。

## 13. 文件

```
docs/quality/
  README.md              本文
  scripts/
    lib.sh               共用函数（不要单独运行）
    00-gen-keys.sh       生成密钥包：服务端一份 + 每客户端一份
    10-server.sh         服务端：装 fwknopd、渲染配置、改防火墙（--status/--uninstall/--purge）
    20-client.sh         客户端：装 fwknop、写 ~/.fwknoprc 与 ~/.ssh/config（--status/--uninstall）
```

三个脚本都幂等，改完配置重跑即可。所有渲染出来的文件都带「勿手改」标记并由脚本覆盖，`--uninstall` 会还原。