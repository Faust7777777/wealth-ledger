# 公共报价有界并发与部署回执

## 目的

公共报价 lookup 原先逐个请求投资标的。账户中存在较多股票或基金时，外部请求耗时会线性叠加，100 个标的尤其明显。本批只优化只读报价查询，不改变候选审核、权威报价写入或持仓规则。

## 实现

- `public` provider 的标的请求改为有界并发，默认最多同时执行 8 个请求。
- 超过上限的目标分批调度；返回结果仍严格保持输入顺序。
- 单项网络或数据失败只留在对应结果位置，不取消其他目标。
- CoinGecko 共享响应仍只发起一次，不因并发重复请求。
- FX 查询保持顺序执行；本批优先解决大量股票、基金或独立 crypto ticker 的主要瓶颈。

## 回归与真实验证

- 新增并发上限测试：测试上限为 3，观测峰值恰好为 3，且结果顺序与请求顺序一致。
- 新增失败隔离测试：慢、快、失败请求以不同顺序完成，最终结果仍按输入顺序返回，失败不连带取消。
- Rust 全量 `162 passed`，OpenAPI/契约检查通过。
- 本地真实公网 smoke：AAPL、MSFT、GOOG、AMZN、META、NVDA、TSLA、JPM、XOM 与 510300 共 10 个标的全部获得结构化报价；lookup 前后权威报价均为空。
- VPS 候选在临时端口、临时账本和 `FINWEALTH_QUOTE_PROVIDER=public` 下重复上述 10 标的验证：10 条均成功，顺序稳定，权威报价写入数为 0。临时服务与账本随后删除。

## 部署

- 实现提交：`07ef32a`，已推送 `origin/feat/integration-self-use`。
- VPS 候选使用生产服务正在运行的真实进程环境完成 `--check-production-config`，避免把 systemd EnvironmentFile 误当 shell 脚本解析；整个过程未输出环境值。
- 候选离线验证生产账本与 auth state 成功。
- 部署前账本/auth 备份：`/var/backups/finwealth/20260730-220627Z`。
- 旧 Rust 二进制回滚目录：`/opt/finwealth/rollback-20260730-220627Z`。
- 安装二进制 SHA-256：`b083cb24cd223be397e3325e59364c17fe06545bf28aa10b7369af0b5dfde920`，与候选逐字节一致。
- Rust 与 Agent 服务均为 active；`check_vps_readiness.sh --public-base-url https://wuwaidut.com` 与公网 health 通过。
- VPS 临时源码和上传归档已按精确 `realpath` 校验后清理，根分区约 39 GB 可用。
- 未修改 Flutter、生产账本内容、Agent state、Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。

## 后续

- 真实文件到结构化持仓的链路仍需补充缺失标的的确定性创建/匹配和逐项诊断。
- 港股及更多市场需要明确交易所代码与数据源映射后再接入，不能按证券代码猜测。
- FX 查询若在大批量跨币种账户中成为瓶颈，可复用同一有界并发原语；当前请求规模下不作为 P0。
