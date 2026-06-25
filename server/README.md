# Finwealth dev server skeleton

这是服务端 skeleton，不是真实生产服务。

用途：

- 验证 `openapi_v1.yaml` 的核心接口形状。
- 给前端后续 `api_mock` / `api_remote` 联调提供本地目标。
- 证明服务端不会暴露转账、下单、AI 自动写账、优惠券规划等禁止能力。

边界：

- 只绑定 localhost。
- 不写数据库。
- 不写正式账本。
- 不接真实 AI。
- 不接真实行情。
- 不做真实同步。
- 不保存密码或 token。
- POST 请求不产生持久化副作用。

运行：

```bash
python server/dev_server.py
```

默认地址：

```text
http://127.0.0.1:8788
```

示例：

```bash
curl http://127.0.0.1:8788/v1/health
curl http://127.0.0.1:8788/v1/portfolio/overview?scenario=degraded
```

与 `tools/mock_api_server.py` 的区别：

- `tools/mock_api_server.py` 更像纯 examples server，只返回示例载荷。
- `server/dev_server.py` 是未来真实服务端的骨架位置，包含 auth/sync/空资源列表等基础路由，但仍不持久化。

