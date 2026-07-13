# SERVER_MODE_ALGORITHMS_V1

状态：服务器自用模式的实现口径。本文描述当前 Rust JSON 账本实际执行的算法，
不是未来规划。

## 1. 运行模型

- VPS 上的 `ledger.json` 是在线模式唯一业务事实源。
- Windows 客户端以 `DATA_SOURCE=api_remote` 连接同一个 HTTPS API；客户端不维护
  第二份可写账本，因此在线共享使用不依赖离线 sync merge。
- Windows/Android 通用客户端首次启动校验并保存 HTTPS origin；切换 origin 时先清除
  旧服务器 token，防止跨主机凭证复用。地址配置本身不含秘密。
- Rust 服务只监听 loopback，由 Caddy/Nginx 终止 TLS。Host 必须在显式允许列表中。
- 一个 ledger 同时只允许一个 Rust 进程持有 OS 文件锁，不支持 active-active 或共享盘多写。

## 2. 金额与分录

- 所有金额以十进制定点字符串保存和计算，不使用二进制浮点数。
- `direction=in` 对账户/持仓增加金额，`direction=out` 减少金额。
- 无 `instrumentId` 的腿更新账户对应币种的 `cashBalances`；有 `instrumentId` 的腿
  更新 `(accountId,instrumentId)` 持仓。
- 确认前的 `draft`、`pending_review` 不改变余额。只有确认 atomic group 才应用全部腿。
- 任意一腿校验或落盘失败，整个账本替换失败，不保留部分余额变化。
- 持仓数量不得因 out 腿变为负数；普通资产账户出现负现金余额会进入异常提示。

## 3. 转账、投资与更正

- 转账是同一 atomic group 内的多腿 movement；来源腿 out，目标腿 in。
- 已确认 movement 永不原地改写。
- 更正由“原 movement 全部腿的反向腿 + 完整 replacement 腿”组成。确认更正前
  余额不变，确认时一次性应用，等价于撤销旧效果再应用新效果。
- 同一原 movement 同时最多存在一个 pending correction；无实际效果变化的更正被拒绝。

## 4. 订阅排期与扣费

- 订阅金额可使用付款账户支持的任意币种。
- 日/周周期使用固定天数推进；月/年周期保存 `billingAnchorDay`。例如每月 31 日在
  二月落到月末，三月恢复 31 日，不发生永久漂移。
- `duration` 从 `startDate` 计算包含式 `endDate`；也可直接指定 `endDate`，两者互斥。
- due scan 只选择 `trial|active` 且 `nextChargeDate <= throughDate` 的订阅，按
  `(nextChargeDate,id)` 稳定排序。
- 每个订阅同时最多一个 pending 扣费候选。付款账户归档或不支持币种时单独报告，
  不阻断其他订阅扫描。
- 扫描只生成 `pending_review` expense，不改变余额或日期。确认后才扣减付款账户、
  设置 `lastChargeDate` 并推进 `nextChargeDate`；超过 `endDate` 后变为 `expired`。
- 拒绝候选会清除 pending 指针，原扣费日期保持不变，可重新生成。

## 5. 净值与估值

- 纳入净值且未归档的资产账户计入 gross assets；负债账户取账户绝对值计入 liabilities。
- 非负债账户若合计为负，按异常负债计入并降低数据质量。
- 非本位币现金必须存在 FX；持仓必须存在可换算到本位币的估值。缺失报价不会猜值，
  该部分标记 incomplete/unpriceable。
- `netWorth = grossAssets - totalLiabilities`。资产配置只对正资产分组，不把负债混入分母。

## 6. 幂等与并发

- 所有持久化写请求必须带 `Idempotency-Key`。
- 服务端保存 key 哈希、规范化请求哈希和成功响应；相同请求重试回放原响应，不重复记账。
- 同 key 不同请求返回 409。记录保留 30 天，最多 5000 条。
- 业务变更与幂等记录在同一次 ledger 原子替换中提交。

## 7. 认证

- 部署模式强制 Argon2 密码哈希，不允许明文密码环境变量。
- access token 有效期一小时，refresh token 有效期 30 天；服务端只存 token SHA-256 哈希。
- refresh 时旋转 access/refresh token。设备撤销和 logout 必须成功持久化后才返回成功。
- auth 状态使用临时文件写入、`sync_all`、rename 和文件同步；损坏的 auth 文件会阻止
  服务启动，不会静默重置为空状态。

## 8. 持久化、恢复与边界

- ledger 写入先完整校验，再写 `.tmp`、同步、rename、同步主文件；Unix 额外同步父目录。
- 主文件缺失时只提升可解析且通过完整校验的 temp；无效 temp 会阻止初始化空账本。
- 备份必须同时包含 ledger、auth、manifest 与 SHA-256；恢复失败时双文件回滚。
- 当前 AI 导入是结构化候选生成与人工复核，不调用真实模型。
- 当前不接银行、券商或服务商支付 API，不自动执行转账、下单或外部退订。
- 离线多设备双向合并仍未完成；服务器在线模式通过所有客户端访问同一事实源实现共享。
