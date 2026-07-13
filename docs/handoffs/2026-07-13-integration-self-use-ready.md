# 2026-07-13 自用集成线收口交接

分支：`feat/integration-self-use`。集成基线：`fd2f8cb`，已包含
`feat/backend-hardening@dd93d3b` 与 `feat/frontend-skeleton@31ff676`。
本文件所在提交是本轮准备推送的完整源码状态；不得直接改写 `main` 或创建 Release。

## 本轮完成

- 修正 Flutter local-server 查询映射：recent movement 透传 `limit`，latest snapshot 使用专用端点。
- 修正 `{ok:true,data:null}` 被误映射为整个 envelope 的问题，空快照现在返回 `null`。
- 新增 Flutter Repository → HTTP → Rust `--ledger-path` 的订阅真实联调：创建、编辑、外币、候选、确认、拒绝、冲突、取消和余额变化。
- 修正订阅 PATCH nullable 排期四态：仅 `duration` 与 `endDate` 都非空时冲突；支持时长、固定日期与无限期之间切换。
- 拒绝空对象订阅 PATCH，避免只改 `updatedAt` 并制造无意义 sync change。
- 将真实 local-server smoke 接入 CI、Package workflow 与静态契约守卫；Windows PowerShell 多命令门禁拆成单命令 step，避免前序失败被后续成功覆盖。
- 固定 Python 工具依赖 `PyYAML==6.0.3`，CI 现在实际执行 `contract_check.py`。
- 补齐 SubscriptionService / use cases / store port、Rust 持久化资源、订阅路由和 ledger+auth 备份恢复文档。
- `.gitignore` 显式排除 `.env`、私钥/签名容器及真实 ledger/auth 文件；高特异凭据扫描为 0 命中。

## 真实实现与空壳边界

| 资产 | 当前性质 | 可作为写入验收依据 |
| --- | --- | --- |
| Rust `--ledger-path` + `local_server` Flutter Repository | 真实 JSON 持久化、幂等、认证、订阅和确认后写账 | 是 |
| Flutter `real_local` | 只读空壳 adapter，不直接打开 JSON | 否 |
| `debug_fixture` / Python mock-dev 服务 | 演示、接口形状和 smoke | 否 |
| AI 导入 | 规则化候选与人工复核；无模型推理 | 仅候选/复核流程 |
| Sync | 本地 change log、pull/ack/relay；无完整远端 entity merge | 否 |
| 支付/自动续费/服务商退订 | 未实现，订阅只管理计划并生成待确认账本候选 | 否 |
| Android 可写数据源 | 未决定 Rust FFI 或认证 VPS | 否 |

## 已执行门禁

- `cargo fmt --check`、Rust tests：80 passed、Clippy `-D warnings`。
- `flutter analyze`：No issues；`flutter test`：82 passed / 13 skipped / 0 failed。
- `python tools/contract_check.py`：63 paths / 108 schemas，全绿。
- mock/dev/Rust server smoke、真实 local-ledger smoke：通过。
- Flutter↔Rust local-server subscription smoke：PowerShell 5.1 与 PowerShell 7 均通过。
- Windows ledger+auth backup/restore smoke、package integrity smoke：通过。
- workflow YAML、全部 PowerShell 脚本语法、`git diff --check`：通过。

正式 Windows 包必须在提交后的干净工作树执行：

```powershell
pwsh -NoProfile -File tools\package_release.ps1 `
  -WindowsOnly `
  -OutputDir tmp\package-integration
```

不得用 `-AllowDirtySource` 代替发布验证；失败则不得推送本轮集成提交。

## Claude 前端后续

独立任务单：
`docs/handoffs/2026-07-13-claude-subscription-cancel-followup.md`。

P0 是修正 pending charge 时「取消订阅」按钮仍可用的问题，并补 pending/non-pending widget 测试。后续 Claude 应从本集成分支派生或同步；`finwealth` 工作树中的旧契约仍停留在订阅接入前，不再作为权威。

## 已知后续决策

- pending charge 存在时，服务端目前允许编辑订阅；候选 movement 保存生成时的金额、账户和计费日期，确认后的下一期排期使用订阅当前计划。若产品希望 pending 期间完全冻结编辑，应另行定义 409 规则并补前后端测试。
- 后端下一切片优先级：订阅到期批量扫描、显式 migration registry、跨进程账本文件锁；远端同步只先做认证设备的 `account/create` inbound apply。

## 资产保护

1. 本集成提交是唯一尚未远端化的完整前后端闭环，门禁与干净打包通过后应立即推送 `feat/integration-self-use`。
2. `finwealth-corrections/lib/shared/widgets.dart` 仍是独立未提交资产；不要在后续 redesign 合并中覆盖，应单独备份/提交。
3. 本地产生的发行 ZIP、账本、auth、日志和临时备份不进入 Git；如需留存 ZIP，放到独立发布归档。

本交接不包含 token、密码、真实账本内容或其他秘密。
