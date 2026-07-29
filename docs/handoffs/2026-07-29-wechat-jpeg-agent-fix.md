# 微信 JPEG 附件上传修复

## 症状

Android Agent 面板选择微信保存的 `.jpg` 后显示“文件内容与扩展名不一致”；附件没有进入 Agent 工作区，模型随后只能猜测设备路径并报告路径不存在。

## 根因

真实样本是标准 JFIF/JPEG，但微信在 `FF D9` 结束标记后附加了 22 字节私有元数据。sidecar 旧校验错误地要求 EOI 必须是文件最后两个字节，因此误报 MIME mismatch。

## 修复

- JPEG 仍必须以 `FF D8` 开始并包含 EOI。
- 允许 EOI 后最多 4 KiB 的应用元数据；更大的拼接载荷仍拒绝。
- Node 回归覆盖微信式 22 字节 trailer 和超限 trailer。
- Agent local smoke 覆盖 Rust multipart proxy、sidecar 归档及 JPEG 原字节回读。
- 用户提供的真实 `759287` 字节微信 JPEG 已通过同一校验函数。

图片上传成功后由 Pi 直接接收归档图片的 base64 与 MIME，不依赖手机原始文件路径。
