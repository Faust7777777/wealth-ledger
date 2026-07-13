# AI_PROPOSAL_SCHEMA_V1

状态：草案冻结给前端 AI Review 使用。  
用途：定义 AI 导入、AI 修改、AI 更正、AI 归档建议的候选数据结构与审批边界。  
非用途：不定义具体模型供应商、不定义 prompt、不允许 AI 直接写账。

## 0. 强约束

1. AI 只能生成 proposal，不能直接写入正式账本。
2. 用户确认前，proposal 不影响余额、流水、净值、快照。
3. 最小确认单位是 `atomic_group`。
4. 多腿交易必须整组接受或整组拒绝。
5. 修改已有记录必须显示 old → new diff。
6. 修改 confirmed 记录时，默认生成更正事件；除非用户显式选择“修改原记录”。
7. confidence 不作为盲签依据；证据、diff、警告必须可见。
8. 已持久化在 `movements` 的 standalone `pending_review` 候选只做读取投影，不得为了进入 AI Review 再复制成 `aiProposals` 记录。

## 1. 顶层结构

```ts
AiProposal {
  id: ID;
  status: AiProposalStatus;
  source: AiProposalSource;
  atomicGroups: AiAtomicGroup[];
  summary?: string;
  warnings: AiWarning[];
  createdAt: ISODateTime;
  reviewedAt?: ISODateTime;
}

AiProposalStatus =
  | "pending"
  | "partially_reviewed"
  | "approved"
  | "rejected"
  | "edited"
  | "expired";
```

规则：

- `approved` 表示 proposal 下所有 atomic group 都已处理完成。
- 单个 atomic group 可独立审批，但 group 内多腿不可拆开。

## 2. 来源与证据

```ts
AiProposalSource {
  kind: "user_text" | "image" | "csv" | "manual_import" | "web_lookup";
  evidenceRefs: EvidenceRef[];
  modelName?: string;
  promptVersion?: string;
  inputDigest?: string;
}

EvidenceRef {
  id: ID;
  type: "text" | "image" | "file" | "url";
  label: string;
  uri?: string;
  excerpt?: string;
  capturedAt?: ISODateTime;
}
```

规则：

- 图片、多模态输入可以直接作为 evidence，不要求单独 OCR UI。
- 若 AI 通过联网搜索补全价格或规则，必须附 URL evidence，用户确认后才可采用。
- evidence 不应暴露用户不需要看的原始敏感内容；必要时只显示摘要。

## 3. Atomic Group

```ts
AiAtomicGroup {
  id: ID;
  title: string;
  operation: AiOperation;
  targetType: AiTargetType;
  targetId?: ID;
  proposedMovements?: Movement[];
  proposedEntities?: ProposedEntity[];
  diffs?: AiFieldDiff[];
  warnings: AiWarning[];
  status: AiAtomicGroupStatus;
  validation: AiValidationResult;
  subscriptionId?: ID;
  scheduledChargeDate?: ISODate;
}

AiOperation =
  | "create"
  | "modify"
  | "correction"
  | "merge"
  | "classify";

AiTargetType =
  | "account"
  | "holding"
  | "movement"
  | "dca_plan"
  | "category"
  | "counterparty";

AiAtomicGroupStatus =
  | "pending"
  | "approved"
  | "rejected"
  | "edited";
```

规则：

- `create`：创建新账户、记录、分类、对手方等候选。
- `modify`：修改未确认或允许直接编辑的对象，必须展示 diff。
- `correction`：对 confirmed 记录生成反向/更正事件，优先于原地改写。
- 多腿 correction 必须整组包含原分录反向腿与完整替换腿，不允许只更正其中一腿或拆分审批。
- `merge`：用于对手方归并，例如“瑞幸”与“瑞幸咖啡”。
- `classify`：用于分类/标签建议。
- subscription 扣费候选的 group 必须携带 `subscriptionId` 与 `scheduledChargeDate`，便于调用方定位计划和计费期。

## 4. Proposed Entity

```ts
ProposedEntity {
  id: ID;
  entityType:
    | "account"
    | "movement"
    | "category"
    | "counterparty"
    | "dca_plan";
  payload: unknown;
}
```

规则：

- `payload` 必须能映射到 `DATA_SCHEMA_V1` 中的正式实体。
- 前端不得把未知 payload 直接写入正式账本。

## 5. Diff

```ts
AiFieldDiff {
  fieldPath: string;
  oldValue: unknown;
  newValue: unknown;
  severity: "normal" | "important" | "danger";
  reason?: string;
}
```

UI 规则：

- `oldValue` 与 `newValue` 必须并排可见。
- 金额、账户、日期、币种变化默认 `important`。
- 从 confirmed 记录改为其他金额/账户/币种默认 `danger`，除非作为 correction 展示。

## 6. Warning 与 Validation

```ts
AiWarning {
  code: string;
  message: string;
  severity: "info" | "warning" | "critical";
}

AiValidationResult {
  isValid: boolean;
  errors: AiValidationError[];
}

AiValidationError {
  fieldPath?: string;
  code: string;
  message: string;
}
```

必须校验：

- atomic group 是否平衡或能解释不平衡。
- 金额、币种、账户是否完整。
- 转账在途状态是否合理。
- `paidAmount` 是否与 `grossAmount - savingsAmount` 一致。
- confirmed 记录是否被直接改写。

## 7. 审批动作

```ts
ApproveAtomicGroup {
  atomicGroupId: ID;
  reviewedAt: ISODateTime;
}

RejectAtomicGroup {
  atomicGroupId: ID;
  reason?: string;
  reviewedAt: ISODateTime;
}

EditAtomicGroup {
  atomicGroupId: ID;
  patch: unknown;
  editedAt: ISODateTime;
}
```

规则：

- edit 后必须重新校验。
- approve 只对通过校验的 group 生效。
- approve 后写入正式账本的结果必须可追溯到 proposal id。

## 8. DCA proposal

定投提醒的“记录已执行”生成 pending proposal / draft，而不是外部交易执行。

```ts
DcaExecutedProposal {
  reminderId: ID;
  planId: ID;
  proposedMovement: Movement;
}
```

规则：

- 不连接券商。
- 不下单。
- 不转账。
- pending proposal / draft 可以持久化，以便刷新或重启后继续复核。
- 用户确认前不写 confirmed/effective ledger，不影响余额、持仓、净值或快照。
- 用户确认 atomic group 后才生成正式 Movement。

## 9. Standalone pending movement 投影

订阅扣费、DCA 记录或手工候选可以直接以 `Movement.status = "pending_review"` 持久化，而不属于 AI 模型生成的 `aiProposals`。AI Review 读取层必须让这些候选在刷新或服务重启后仍可发现。

```ts
StandalonePendingProjection {
  id: `proposal_movement_${movementId}`;
  status: "pending";
  source: {
    kind: "manual_import";
    evidenceRefs: EvidenceRef[];
  };
  atomicGroups: AiAtomicGroup[];
  warnings: AiWarning[];
  createdAt: ISODateTime;
}
```

规则：

- 读取 `movements` 中的 `pending_review` 项，按 `atomicGroupId` 分组；组内 movement 按 ID 稳定排序，再动态构造 proposal。
- synthetic proposal 不是新的磁盘实体，不写入 `aiProposals`，也不产生第二份 movement。
- `GET /ai/proposals/pending`、`GET /ai/proposals/{proposalId}` 与 overview `aiPendingCount` 都包含该投影。
- approve/reject 直接消费底层 movement atomic group；处理完成后投影自动从 pending 读取结果消失。
- standalone 投影不可原地 edit；编辑请求返回冲突，用户应拒绝后从订阅、DCA 或手工录入命令重新生成。
- subscription 投影使用 `subscription_charge_requires_confirmation` warning；确认前不扣款、不推进 `nextChargeDate`。
