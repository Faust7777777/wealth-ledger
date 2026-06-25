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

SyncPullResponse {
  cursor: string;
  changes: SyncChange[];
  conflicts: SyncConflict[];
}
```

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

