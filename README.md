# cyprinus-surge · 自建跨境科研网络方案

一套「文档 + 可执行脚本」的自建代理工程包：面向稳定性优先、延迟 ≤500ms、IP 纯净度 Fraud Score ≤20、支持规则/全局分流、能正常使用 ChatGPT / Google / YouTube 的个人科研用途场景。

不是机场推荐，也不承诺「无法被识别」；目标是把**入口抗封锁、出口纯净度、分流体验**三个问题拆开，让任一层失效时能独立替换而不是全盘重装。

## 核心设计

| 层 | 选择 | 理由 |
|---|---|---|
| 服务器 | 1C1G 优化线路 VPS（CN2 GIA / AS9929 / CMIN2），支持换 IP 或按小时计费 | 延迟由**线路**决定，不由配置决定 |
| 主入口 | VLESS + XTLS-Vision + REALITY（TCP/443） | QUIC/UDP 出境被干扰，TCP/443 更像正常 HTTPS |
| 备入口 | Hysteria2（QUIC/UDP + obfs + 端口跳跃，可选） | 弱网/丢包/移动网络的吞吐兜底 |
| 客户端 | sing-box ≥1.14.x，一份 JSON + TUN 覆盖 Windows / macOS / Android | 规则三端完全一致，便于命令行复现问题 |
| 分流 | `route` + 远程 `rule_set`（.srs），另备全局配置 | 规则可远程更新，不写死 IP 表；DNS 单独接管防泄露 |
| AI 出口 | 与主线路解耦：专用落地 VPS（首选）→ 静态 ISP → WARP（仅兜底） | 机房 IP 天然被 AI 风控歧视，出口要可换可测 |

相对原始需求稿（[prompt.txt](prompt.txt)）的三处校准：主备入口反转、AI 出口优先级反转（WARP 已被 OpenAI 定向拒绝过）、配置语法对齐 sing-box 1.14（GeoIP/GeoSite 与 WireGuard 出站的旧写法已失效）。

## 可验收指标

| 需求 | 通过标准 |
|---|---|
| 全平台 | 三端导入同一份 JSON，`sing-box check` 通过，TUN 生效 |
| 延迟 | 晚高峰握手 RTT ≤200ms（美西）/ ≤80ms（亚洲），代理后 TTFB ≤500ms |
| 稳定性 | 晚高峰 jitter ≤30ms、丢包 ≤1% |
| IP 纯净 | IPQS Fraud Score ≤20 且 proxy/vpn/tor/recent_abuse=false，**并实测 ChatGPT 登录可用** |
| 分流 | 国内直连不出境、AI 域名走独立出口（出口 IP ≠ 主出口）、全局模式可切换 |

## 仓库结构

```
docs/
  方案.md                 完整文字方案：选型/协议/分流与 DNS/IP 门禁/运维/验收/风险
  index.html              推荐入口：单文件可视化方案（内联四张架构图，可离线打开）
  vps-shortlist.html      采购清单：6 家厂商 8 个机型，含线路、价格、换 IP 能力
  deploy/index.html       部署手册：6 步主流程（每步内联对应脚本源码，避免文档漂移）
  deploy/onekey.html      一键脚本说明（交互模式、参数、卸载行为）
  deploy/troubleshooting.html  独立排查手册
  deploy/scripts/         可直接拷到服务器执行的脚本
  diagrams/               四张交互式架构图 + 校验回执 JSON
  README.md               文档索引
prompt.txt                原始需求稿
```

`scripts/` 的关键约定：

- **幂等**：每个步骤都有 `*_check()`，重跑只会补齐缺失部分；参数集中在 `/etc/sing-box/deploy.env`。
- **生成物不手改**：`deploy.sh` 由 `build-onekey.sh` 把 `lib.sh` + `steps/*.sh` + `onekey/driver.sh` 拼成单文件；单步入口（`10-install-singbox.sh` 等）与一键脚本调用同一份实现，行为一致。
- **配置由模板渲染**：`templates/*.json.tmpl` + 变量替换，落盘前用 `sing-box check` 挡住语法错误。
- 步骤：`system`（BBR/swap/时间同步/防火墙）→ `install`（固定版本 + systemd）→ `secrets`（生成 deploy.env / client.env）→ `server`（双入口渲染并启动）→ `hy2`（可选 ACME DNS-01 证书）→ `porthop`（可选端口跳跃）。

## 快速开始

```bash
scp -r docs/deploy/scripts root@<服务器IP>:/root/deploy
cd /root/deploy && bash deploy.sh --dry-run   # 先看计划
cd /root/deploy && bash deploy.sh             # 交互：逐步骤询问 复用/覆盖/跳过
```

常用参数：`--only server --overwrite --yes`、`--skip hy2`、`--status`、`--uninstall` / `--purge`、`--reinstall`。详细用法见 [docs/deploy/onekey.html](docs/deploy/onekey.html)。

## 维护文档

- `docs/deploy/*.html` 由 `.build/deploy/build.mjs` 从 `.build/deploy/pages/` 模板生成，并把 `scripts/*` 内联进页面；改脚本后重跑构建即可。
- `docs/diagrams/*.html` 由 [archify](https://github.com/tt-a1i/archify) 生成，同目录 `*.finalize-summary.json` 为 validate/deliver/check/browser-check 的校验回执。
- `.build/`、`.archify/`、`data/` 为本机工具与运行产物，已在 `.gitignore` 中排除（`data/` 含真实 `client.env` 与凭据，勿提交、勿外发）。

## 合规与风险

仅限本人自用、科研学习用途，遵守所在地法律法规与服务条款；不分享账号、不转售节点。IP 被封、线路劣化、上游风控策略变化都是常态，方案提供的是「可测量、可替换」的路径，而非稳定性保证。
