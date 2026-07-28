# Claude 前端 P0：Agent 不得把登录失效显示成模型未配置

日期：2026-07-28

## 实机复现

- 产物：`finwealth-1.0.0+1-20260728-163454-android-server-client-debug.apk`
- 环境：Android 36.1 `Small_Phone` AVD，真实 `https://wuwaidut.com`
- AVD 中保留一份已失效的 Android Keystore 会话；服务端公网 Agent 路由和模型配置均正常。
- 概览请求返回 401 后，主界面正确显示“需要登录”并可进入设置登录区。
- 打开 Agent 全屏页却显示“服务器尚未配置模型”和“连接已断开”。这是错误结论：真实原因是登录态失效。
- Android 返回键可正确关闭 Agent 页并回到主界面，该项已通过。

## 根因

`AgentPanel.build` 当前使用：

```dart
final configured = statusAsync.asData?.value.configured ?? false;
```

因此 loading、401、网络错误和服务端错误都会被折叠成 `configured=false`。会话列表错误也回落为空列表，进一步呈现“还没有对话”。

## 修复要求

1. 只有 `/v1/agent/status` 成功返回且明确 `configured=false` 时，才显示“服务器尚未配置模型”。
2. `ApiUnauthorizedException` 显示简短“需要登录”状态，并提供进入设置登录区的动作；不得同时显示“模型未配置”。
3. 网络或其他加载失败显示可重试错误，不得伪装成空会话或模型配置状态。
4. access 401 后 refresh 也明确返回 401 时，清除失效 token，并让 `authControllerProvider` 同步为未登录。网络失败、超时和 5xx 不得清除登录态。
5. 并发请求同时遇到失效会话时仍只执行一次 refresh 和一次本地失效处理。
6. 不增加常驻解释性或防御性文案。

## 必须补的测试

1. status 200 + `configured=false`：只在这条路径显示模型未配置。
2. GET status 401、refresh 401：清除 token、Agent 显示需要登录、不显示模型未配置或空会话。
3. GET status 401、refresh 成功：复用新会话重放并正常进入 Agent。
4. status 网络失败/503：保留 token，显示重试，不显示模型未配置。
5. 两个并发 401：refresh 和 session invalidation 各一次。
6. Android 360×640/720×1280 下错误态无 overflow，返回键仍先关闭 Agent 页。

## 复验

修复分支合入后，Codex 会重新构建 APK，在同一无窗口 AVD 上完成：登录失效状态、真实 Agent 全屏、输入法顶起、会话切换、历史附件 chip 和断线重连。
