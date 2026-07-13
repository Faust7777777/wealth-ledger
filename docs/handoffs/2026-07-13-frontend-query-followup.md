# 2026-07-13 前端查询语义小跟进

优先级：P2，不阻塞当前订阅 P0。Claude 完成订阅与测试后再处理；只改 Flutter。

后端已按既有契约落实：

- `GET /v1/movements?status=<status>&limit=1..200`：先过滤再截断。
- `GET /v1/movements/recent?limit=1..200`：稳定 recent-first，缺省 20。
- `GET /v1/snapshots`：无参数返回全部持久化快照，按 `snapshotAt` 倒序。
- `GET /v1/snapshots?from=YYYY-MM-DD&to=YYYY-MM-DD`：可选的包含首尾范围，必须成对出现。

前端当前有两个小问题：

1. `LocalServerMovementRepository.listRecentMovements({limit})` 忽略 `limit`，固定请求
   `/v1/movements/recent`。改为安全拼接 `?limit=$limit`，并为 1、20、200 增加 mapping
   测试；非法值由调用层防止，服务端仍会返回 400。
2. `LocalServerSnapshotRepository.getLatest()` 通过 `listSnapshots().first` 间接读取。
   当前服务端倒序后行为正确，但可改为直接请求 `/v1/snapshots/latest`，减少载荷并避免
   未来排序耦合。

不要为默认列表强行添加 `from/to`；它们现在是可选成对过滤器，与现有
`SnapshotRepository.listSnapshots()` 无参数接口兼容。
