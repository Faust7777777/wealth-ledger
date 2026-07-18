# Claude 前端 P0：订阅开始日期与下次扣费日分离

日期：2026-07-18  
基线：恢复时同步 `origin/feat/subscription-sync-integration` 最新提交。

## 用户场景

用户本月已经续费，希望从下个月开始记录，例如下一次扣费为 `2026-08-17`。当前表单只有“开始日期”，没有“下次扣费日”；Create/Update VM 和 HTTP body 也漏掉了服务端已经支持的 `nextChargeDate`。

编辑已有订阅时把开始日期改到未来，会保留旧的下次扣费日并收到原始错误：

```text
subscriptions[0].nextChargeDate must be on or after startDate
```

## 必须修改

1. CreateSubscriptionInput 和 UpdateSubscriptionInput 增加 `nextChargeDate`。
2. `_createSubBody` / `_updateSubBody` 显式映射该字段。
3. 表单同时显示：
   - `订阅开始日期`；
   - `下次扣费日`。
4. 新建时下次扣费日默认等于开始日期；用户可以改成下个月或更晚。
5. 开始日期变化时：
   - 下次扣费日从未手动修改：同步到新的开始日期；
   - 已手动修改：保留用户值，但提交前校验不得早于开始日期。
6. 编辑已有订阅时使用服务端 `nextChargeDate` 初始化，不根据本地当前日期猜测。
7. 400 错误用户化：显示“下次扣费日不能早于订阅开始日期”，不得展示 `subscriptions[0]`、wire 字段或英文校验文本。

## 验收测试

- 本月已付、下月 17 日再扣：创建成功，nextChargeDate 为下月 17 日。
- 编辑旧订阅，只把开始日期移到旧 nextChargeDate 之后：后端返回的新 nextChargeDate 等于新开始日期。
- 用户显式选择晚于开始日期的 nextChargeDate：原值保留。
- 用户选择更早日期：前端阻止提交并显示中文字段错误。
- Create/Update HTTP body 真实断言字段；360/1200 宽无 overflow。

## 边界

- 不把开始日期改名成下次扣费日；这是两个不同概念。
- 不修改后端/契约/生产数据；集成交回 Codex。
