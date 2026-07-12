# SYNC_API_DRAFT

状态：草案。  
用途：定义未来 VPS 同步、登录、设备、冲突处理的方向。  
非用途：不是当前前端第一阶段任务，不要求 Claude 实现。

## 0. 目标

同步服务用于：

- Android 与 Windows 多设备同步。
- 备份。
- 登录与设备授权。
- 未来行情/AI 服务代理。

同步服务不用于：

- 转账。
- 下单。
- 访问银行/券商交易权限。
- 同步 debug fixture。

## 1. 部署假设

- 用户有 Oracle VPS，可运行在 ARM。
- 个人自用，低并发。
- 可以使用现有个人域名的子域名，例如 `api.example.com`。
- 反代可用 Caddy / Nginx / Traefik。

## 2. 认证

MVP：

- 账号密码登录。
- 长期 refresh token 实现秒登。
- 暂不做 2FA。

```http
POST /auth/login
POST /auth/refresh
POST /auth/logout
GET  /auth/devices
POST /auth/devices/revoke
```

规则：

- 服务端只存密码哈希，禁止明文密码。
- Android 使用 Keystore 保存 token。
- Windows 使用系统凭据存储保存 token。
- token 不写入日志。

## 3. 同步模型

推荐方向：操作日志 / 变更集同步。

```ts
SyncChange {
  id: ID;
  deviceId: ID;
  entityType: SyncEntityType;
  entityId: ID;
  operation: "create" | "update" | "delete" | "correction";
  payload: unknown;
  baseVersion?: number;
  createdAt: ISODateTime;
}

SyncEntityType =
  | "account"
  | "instrument"
  | "holding"
  | "movement"
  | "dca_plan"
  | "subscription"
  | "category"
  | "counterparty"
  | "quote"
  | "fx_rate"
  | "snapshot"
  | "ai_proposal";
```

## 4. API 草案

```http
GET  /sync/bootstrap
GET  /sync/changes?since=<cursor>
POST /sync/push
POST /sync/ack
```

```ts
SyncPushRequest {
  deviceId: ID;
  lastKnownCursor?: string;
  changes: SyncChange[];
}

SyncPushResult {
  cursor: string;
  acceptedChangeIds: ID[];
  skippedChangeIds: ID[]; // idempotent duplicate push
  conflicts: SyncConflict[];
}

SyncPullResponse {
  cursor: string;
  changes: SyncChange[];
  conflicts: SyncConflict[];
}

SyncAckRequest {
  cursor?: string;        // ack 该 cursor 及之前的本地 pending changes
  changeIds?: ID[];       // 可选：精确 ack 指定 changes
  ackedChangeIds?: ID[];  // changeIds 的兼容别名
}
```

当前 Rust real-local 实现状态：

- 已实现本地 outbox 的第一步：account create / update / archive 会追加 `SyncChange`。
- confirmed movement create / correction 会追加 `SyncChange`；draft、pending proposal、未确认图片/CSV 不进入 outbox。
- `GET /v1/sync/changes?since=<cursor>` 可按本地 cursor 拉取之后的 change。
- 空日志的 genesis cursor 是 `local_cursor_0000`；pull 接受它并返回完整保留日志，ack 它是幂等 no-op。
- 除 genesis 外，未知 cursor 返回 400，不得静默从日志开头重放。
- pull 的 `cursor` 与 `changes` 来自同一次 ledger 快照；新 change sequence 会以日志内最大 `local_change_N` 自愈，避免人工回退计数器后复用 ID。
- `POST /v1/sync/ack` 可清理本地 `pendingChangeIds`，但不删除 `syncChanges` 日志。
- 当前 ack 仅表示单一上游接受了本地 outbox 高水位，不是逐设备 delivery receipt。
- `POST /v1/sync/push` 会把远端 `SyncChange` 作为同步日志中继保存，给它分配本地 server cursor；不会直接应用到账本实体。
- 持久化日志要求 change ID 唯一且严格递增，cursor 必须指向日志尾；pending outbox ID 必须唯一、存在且只属于本地产生的 change。
- 远端 push 的 `deviceId` 不得冒用服务端保留的 `local_device`；`createdAt` 必须是 RFC3339，服务端保存的 `(sourceDeviceId, sourceChangeId)` 必须唯一。
- 暂不做远端 merge、冲突解决、设备密钥和 E2EE。

## 5. 冲突处理

```ts
SyncConflict {
  id: ID;
  entityType: SyncEntityType;
  entityId: ID;
  localChange: SyncChange;
  remoteChange: SyncChange;
  resolution: "pending" | "local_wins" | "remote_wins" | "manual";
}
```

规则：

- 金额、账户、币种冲突默认 manual。
- AI proposal 冲突默认不自动合并。
- confirmed Movement 不静默覆盖。
- 更正事件优先于原地改写。

## 6. 端到端加密方向

用户前面要求同步/备份时考虑端到端加密。MVP 可分阶段：

阶段 1：

- HTTPS。
- 服务端鉴权。
- 服务端数据库最小化保存。

阶段 2：

- 客户端加密账本 payload。
- 服务端只存密文与元数据。
- 设备间密钥恢复流程另行设计。

前端第一阶段不实现 E2EE。

## 7. 不同步内容

禁止同步：

- debug fixture。
- DEMO 数据。
- 本地开发日志。
- 原始敏感输入，除非用户选择作为 evidence 保存。
- token / 密码 / API key。

## 8. 同步状态 UI

```ts
SyncStatus =
  | "synced"
  | "syncing"
  | "offline"
  | "degraded"
  | "conflict"
  | "error";
```

UI 规则：

- `synced` 可低调显示。
- `offline` 使用缓存，不阻塞查看。
- `conflict` 进入待处理区。
- `error` 需要可查看详情，但不应遮挡账本。
