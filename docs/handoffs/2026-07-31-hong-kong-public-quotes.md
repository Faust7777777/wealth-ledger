# 港股公共报价与 VPS 部署回执

## 实现

- 公共报价 provider 支持显式 `HKEX`、`XHKG`、`SEHK` 市场的港股。
- 只接受 `equity` / `fund`、1–5 位正整数证券代码和 `HKD` 计价币种；其他输入 fail-closed，且不会请求 Yahoo。
- 港股代码去除多余前导零后至少补足四位：`700` / `00700` 映射为 `0700.HK`，`9988` 映射为 `9988.HK`。
- Agent 提示词要求港股显式使用 `HKEX + HKD`，仍禁止根据证券代码猜市场。
- OpenAPI、数据契约、契约检查与真实公网 smoke 同步覆盖港股。

## 验证

- Rust 全量测试：`163 passed`。
- Agent 全量测试：`37 passed`；TypeScript check/build 和 `npm audit --omit=dev` 通过。
- 候选使用生产服务进程的真实环境完成 `--check-production-config`，并离线验证生产 ledger 与 auth state；未输出环境值。
- VPS 临时端口、临时账本下真实查询 12 个标的：9 只美股、510300、腾讯 700、阿里巴巴 9988；返回顺序稳定，币种包含 USD/CNY/HKD，lookup 前后权威报价均为 0。
- 安装后的 Rust、Agent dist 分别与构建候选逐字节一致；Rust 和 Agent 服务 active。
- `check_vps_readiness.sh --public-base-url https://wuwaidut.com` 通过。

## 生产部署

- 实现提交：`8df6562`，已推送 `origin/feat/integration-self-use`。
- ledger/auth 备份：`/var/backups/finwealth/20260730-230235Z`。
- Agent state 备份：`/var/backups/finwealth-agent/20260730-230235Z`。
- 旧 Rust 与旧 Agent dist 回滚目录：`/opt/finwealth/rollback-20260730-230235Z-hk-quotes`。
- 安装 Rust SHA-256：`4536c4838f3b1ea3039e49640a02344817e225cd8866171298826e9ab024d449`。
- 未修改生产账本内容、Agent state、Caddy、Cloudflare、`sub2api.wuwaidut.com` 或中转站配置。

## 部署过程说明

首次交换后的自定义等待循环误用了 Rust 端口 `8787`，实际监听端口为 `8790`，因此循环超时并返回失败码。服务本身已正常启动，候选也已完成交换；随后通过 systemd 监听端口、候选逐字节比较和正式 readiness 三重确认。后续部署等待端口必须从现有 systemd 配置确认，不再写死未经核对的端口。

## 后续

- 补齐真实文件到结构化持仓链路中“缺失标的”的确定性创建、匹配和逐项诊断。
- 为报价 lookup 增加可观测的逐项失败原因，避免 Agent 只能报告笼统失败。
- 继续扩展明确交易所映射；不根据纯数字代码推断市场。
