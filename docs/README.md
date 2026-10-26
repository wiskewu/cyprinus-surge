# 自建跨境科研网络方案（2026-10）

面向「稳定性优先、延迟 ≤500ms、IP 纯净度 Fraud Score ≤20、可规则/全局分流、能正常使用 ChatGPT/Google/YouTube」的自建方案文档集。内容按 2026 年的封锁态势与 sing-box 现状校对，并把每条需求写成可测量的验收条件。

| 文件 | 说明 |
|---|---|
| **[index.html](index.html)** | **推荐入口**：单文件方案可视化（内联四张已校验的架构图，可离线打开） |
| [vps-shortlist.html](vps-shortlist.html) | 服务器入门采购清单：满足下单门槛的 6 家厂商 / 8 个机型，含价格、线路、支付宝/Visa 支持、按小时与换 IP 能力 |
| [deploy/index.html](deploy/index.html) | **部署手册**：6 步主流程 + [一键脚本](deploy/onekey.html) + 独立排查手册；页面只写命令与参数，`scripts/deploy.sh` 由 `build-onekey.sh` 从 `steps/*.sh` 生成 |
| [quality/index.html](quality/index.html) | **SSH 加固手册**：仅公钥登录 + `ufw limit` + fail2ban；5 页（[路线选择](quality/index.html) → [客户端配置](quality/01-client.html) → [服务端加固](quality/02-server.html) → [验收与排障](quality/03-verify.html) → [参数与取舍](quality/04-reference.html)），可离线打开 |
| [方案.md](方案.md) | 完整文字方案：选型、协议、客户端配置骨架、分流与 DNS、IP 门禁、运维与故障手册、实施验收、成本、风险、参考来源 |
| [quality/README.md](quality/README.md) | 同一批内容的 Markdown 版：三个幂等脚本（`bin/harden/{client,harden,audit}.sh`）与四步流程 |
| [diagrams/01-architecture.html](diagrams/01-architecture.html) | 图 1 总体架构（独立交互版，可切主题） |
| [diagrams/02-ai-request-path.html](diagrams/02-ai-request-path.html) | 图 2 一次 AI 请求的分流链路 |
| [diagrams/03-failover-lifecycle.html](diagrams/03-failover-lifecycle.html) | 图 3 连接健康与降级切换 |
| [diagrams/04-rollout-workflow.html](diagrams/04-rollout-workflow.html) | 图 4 实施与验收流程（含门禁与回流） |

> `diagrams/*.html` 由 [archify](https://github.com/tt-a1i/archify) 生成；同目录下的 `*.finalize-summary.json` 是校验回执（validate / deliver / check / browser-check 全部通过）。源 JSON 与组装脚本在仓库根的 `.archify/`（本地工具目录，未纳入版本控制）。

> 字体不内联：四张图与 `index.html` 共用 `diagrams/fonts/jetbrains-mono-*.woff2`，经本地预览服务器打开即可（`npm run preview`）。内联会让每页多 88 KB 且无法复用缓存，`npm run lint` 会挡住回退。

> 脚本在仓库根的 `bin/`：`bin/entry.sh` 是入口，`bin/deploy/` 与 `bin/harden/` 是两套流程，`bin/onekey/deploy-onekey.sh` 由 `fragments/build/build-onekey.sh` 从 `bin/deploy/steps/*.sh` 生成。全部幂等，参数走 `deploy.env`，配置由模板渲染并用 `sing-box check` 挡住错误。

> `quality/*.html` 由 `fragments/build/build-quality-docs.mjs` 从 `fragments/pages/quality/` 生成，页面里的脚本片段统一从 `bin/` 读取，避免文档与脚本漂移。

## 三句话结论

1. **服务器**选 CN2 GIA / AS9929 级别、支持换 IP 的 1C1G 小鸡——延迟由线路决定，不由配置决定。
2. **入口**以 REALITY（TCP/443）为主、Hysteria2（UDP + obfs + 端口跳跃）为辅：2026 年 UDP 出境被大范围干扰，主备与 readme 原稿相反，最终以实测为准。
3. **AI 流量**与主线路解耦，走固定干净的独立出口；WARP 只是零成本兜底，不能当主出口（已被 OpenAI 定向拒绝过）。

合规前提：仅限本人自用、科研学习用途，遵守所在地法律法规与服务条款；不对「无法被识别」做任何保证。
