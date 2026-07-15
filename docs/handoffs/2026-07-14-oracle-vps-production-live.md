# 2026-07-14 Oracle ARM64 VPS 生产上线回执

## 1. 服务器与来源

- VPS：Oracle Linux 9.7，`aarch64`。
- 公网 API origin：`https://wuwaidut.com`。
- Rust server 当前来源提交：`a57385e`。
- 当前集成分支：`feat/subscription-sync-integration`。
- 当前生产路由配置来源提交：`0a8c29a`。

部署使用原生 ARM64 静态 musl bundle。上传 sidecar、内部 `SHA256SUMS`、CPU 架构、
无动态 interpreter 和服务器端实际执行均已通过。

## 2. 生产拓扑

```text
Cloudflare HTTPS wuwaidut.com
  -> existing Caddy Docker container
     -> known Finwealth /v1 paths
        -> 172.19.0.1:8791 (Docker bridge only)
        -> systemd-socket-proxyd as finwealth
        -> 127.0.0.1:8790
        -> finwealth-server
        -> /var/lib/finwealth/ledger.json
     -> all other paths
        -> cli-proxy-api:8317
```

- Rust 只监听 `127.0.0.1:8790`。
- bridge relay 只监听 `172.19.0.1:8791`，没有绑定公网接口。
- Rust Host allow-list 只允许 `wuwaidut.com` 与内置 loopback hosts。
- Caddy 根域站点只接受 Cloudflare 来源地址，其他来源返回 403。
- `wuwaidut.com` 使用白名单路径并行分流：已知账本 API 进入 Rust，根路径、
  `/v1/models`、`/v1/chat/completions` 和其他未来中转路由回落到
  `cli-proxy-api:8317`。
- 根域 `/management.html` 返回 404，避免创建一个绕过现有 Sub2API Access
  policy 的第二管理入口。
- 原 `sub2api.wuwaidut.com` site block 未替换；Caddy 使用原子 reload，容器未重启。
- Caddy 原配置备份：
  `/home/opc/sub2api-deploy/Caddyfile.before-finwealth-20260714T0642Z`。
- 并行路由前配置备份：
  `/home/opc/sub2api-deploy/Caddyfile.before-parallel-20260714T0941Z`。

## 3. 已验证门禁

- 生产配置校验：loopback bind、required auth、public Host allow-list 通过。
- systemd server：enabled / active。
- Docker bridge socket：enabled / active。
- 本地、bridge、Caddy container 和公网 `/v1/health` 均返回 200。
- 公网 `wuwaidut.com/` 返回 CLI Proxy API Server 响应。
- 公网 `wuwaidut.com/v1/models` 进入中转站，并返回预期的未认证 401。
- 未认证 `/v1/accounts` 返回 401。
- 错误密码登录返回 `invalid_credentials` / 401。
- 重启前后 ledger SHA-256 均为：
  `569fe0b874bed71e8c76e1be90f4a9fddc494298637ac9fbe6b8a42aa6f650f1`。
- readiness 通过。
- 首次真实备份：`/var/backups/finwealth/20260714-063912Z`。
- 备份 ledger SHA-256 校验和语义校验通过，服务及 bridge 自动恢复。
- 2026-07-15 部署信用卡正余额净值修复后的推荐恢复点：
  `/var/backups/finwealth/20260715-134853Z`。

部署中发现 bridge proxy companion 会阻塞旧版备份停服务流程；提交 `a51f8ac`
修复 backup/restore 停机顺序，并增加 active proxy socket 回归测试。修复已在 VPS
真实备份中验证。

## 4. 固定域名客户端

GitHub Actions run：`29316603799`，全部必需 jobs 成功。

### Windows

- 文件：
  `C:\tmp\finwealth-wuwaidut-clients-29316603799\windows\finwealth-1.0.0+1-20260714-080941-windows-server-client-x64.zip`
- SHA-256：`c829b68951eb862f81738b4fd2cf520f2826765001e1f1059750ebff782eee19`
- `endpointMode=fixed`
- `apiBase=https://wuwaidut.com`
- 解包后 launcher package integrity 通过。

### Android

- 文件：
  `C:\tmp\finwealth-wuwaidut-clients-29316603799\android\finwealth-1.0.0+1-20260714-081130-android-server-client-debug.apk`
- SHA-256：`a1d6b562b37e19ebc321b7ffccdd126247655eea53ec4ffae0140f3bb93ea26b`
- `endpointMode=fixed`
- `apiBase=https://wuwaidut.com`
- `networkPolicyVerified=true`
- debug self-use signing；后续升级必须复用同一 signing key。

两个 artifacts 的 sidecar 与实际 SHA-256 一致，来源均为干净的 `eb53cea`。

## 5. 已完成的带认证生产验收

服务密码由用户直接设置，未进入聊天、仓库或日志。Windows 客户端登录、DPAPI token
持久化和以下真实生产链路均已完成：

- 有效登录态下账户、订阅和设备接口返回 200；
- 创建临时 USD 账户与 ChatGPT Plus 订阅；
- due-scan 只创建 pending 候选，余额保持 `100.00 USD`；
- 重扫返回 `already_pending=1`，没有重复候选；
- AI pending 投影可读取候选；
- 用户确认后才扣款至 `80.00 USD`，日期由 `2026-07-01` 推进到
  `2026-08-01`；
- 重启服务后余额和订阅日期保持，证明数据已持久化；
- refresh token 成功旋转，新 access token 可用，旧 refresh token 返回 401；
- Windows DPAPI token store 已原子更新。

验收临时数据已恢复，正式账本重新为空。完整回执见
`docs/handoffs/2026-07-14-production-authenticated-acceptance-complete.md`。

## 6. 独立安全观察

`https://sub2api.wuwaidut.com/management.html` 在上线后只读复核时直接返回管理页面
200，而较早检查曾返回 Cloudflare Access 302。Finwealth 部署没有修改 Cloudflare
Access、Sub2API site block 或容器；应在 Cloudflare Zero Trust 中单独核查该应用的
Access policy 与 2FA 规则。
