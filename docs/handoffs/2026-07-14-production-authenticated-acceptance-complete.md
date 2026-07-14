# 2026-07-14 生产带认证业务验收完成回执

## 1. 结论

`https://wuwaidut.com` 上的 Rust/Axum 账本已完成带真实登录态的生产验收。
账户、订阅、到期扫描、AI pending、确认扣款、服务重启持久化、refresh token 旋转、
备份与恢复均通过。验收使用明确标记的 TEMP 数据，结束后已恢复为空账本。

全程未输出或写入仓库任何密码、access token、refresh token、私钥或 Cloudflare
凭据。

## 2. Windows 连接故障与修复

最初 Windows 客户端的认证请求表现为 15 至 20 秒超时，但服务器 loopback 和 Docker
bridge 对同一有效登录态均在约 4 毫秒内返回 200。进一步确认本机 Clash Verge 的
Fake-IP DNS 将 `wuwaidut.com` 解析为 `198.18.0.68`，5 次连接仅 1 次成功。

绕过 Fake-IP 后，Cloudflare 两个真实地址连续 6 次全部返回 200。已对本机活动 Clash
配置做最小范围修复：

- `dns.fake-ip-filter` 增加精确域名 `wuwaidut.com`；
- rules 增加 `DOMAIN,wuwaidut.com,DIRECT`；
- 使用 Mihomo 本地命名管道 API 热重载，返回 204；
- 没有修改 `sub2api.wuwaidut.com` 或其他域名规则。

修复后 DNS 返回 `104.21.32.119` 和 `172.67.151.180`，连续 5 次公网 health 均为
200；账户、订阅、设备接口分别返回 200。

该修复属于当前 Windows 用户的 Clash 配置，不在仓库内。若以后切换 Clash profile，
应保留同样的精确 DIRECT 与 Fake-IP filter 规则。

## 3. 临时业务验收

验收前快照：

```text
/var/backups/finwealth/20260714-120317Z
```

该快照通过 ledger 与 auth 语义校验，认证状态包含 1 台设备。

随后创建临时 `100.00 USD` 账户和 `20.00 USD` 月度 ChatGPT Plus 订阅，并验证：

1. 首次 due-scan 创建 1 个 pending 候选。
2. 扫描后账户余额仍为 `100.00 USD`。
3. 第二次扫描 `created=0`、`already_pending=1`。
4. 候选可从 `/v1/ai/proposals/pending` 读取。
5. 确认 atomic group 后 `ledgerWrite=true`。
6. 确认后余额为 `80.00 USD`。
7. `lastChargeDate=2026-07-01`，`nextChargeDate=2026-08-01`。
8. 重启 `finwealth-server.service` 后余额与日期保持不变。

验收完成态另存为：

```text
/var/backups/finwealth/20260714-121447Z
```

之后使用受校验的 restore 脚本恢复验收前快照。恢复后再次确认：

```text
accounts=0
subscriptions=0
ai pending=0
```

## 4. 认证旋转与最终恢复点

空账本恢复后完成 refresh token 旋转：

- refresh 返回 200；
- 新 access token 读取设备列表返回 200；
- 设备数仍为 1；
- 旧 refresh token 重放返回 401；
- 新会话已使用 Windows CurrentUser DPAPI 加密保存。

最终推荐恢复点：

```text
/var/backups/finwealth/20260714-121559Z
```

此备份包含空正式账本和旋转后的当前认证状态，ledger 与 auth 语义校验均通过。

## 5. 当前剩余工作

- Android 真机安装、登录和跨端同账本验证；
- 用户在客户端录入自己的真实账户、GPT/Claude 等订阅信息；
- 前端继续完成已交给 Claude 的密度、说明文案和可用性收尾；
- 在 Cloudflare Zero Trust 单独核查 `sub2api.wuwaidut.com/management.html` 的
  Access/2FA policy。Finwealth 部署没有修改该 policy。
