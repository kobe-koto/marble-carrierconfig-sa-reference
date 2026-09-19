# 脱敏证据索引

这里不是原始 log dump，而是从本次调查中提取的、足以支持技术结论的最小证据。
所有唯一标识、地址、精确小区信息、时间、PID、UID、Binder 地址和 token 已删除或
符号化。

| 文件 | 支持的结论 |
|---|---|
| `01-carrierconfig-policy.txt` | 原始 policy 自相矛盾，RRO 后最终 policy 正确 |
| `02-qti-mode-transition.txt` | `NrConfig 1 -> 0` 可成功设置并回读 |
| `03-cold-boot-reconciliation.txt` | 冷启动最终配置加载后自动执行 query/set/verify |
| `04-network-result.txt` | combined 后完成 NR SA 注册且数据正常 |
| `05-static-call-chain.txt` | QTI 有服务端 API，但 ROM 缺少 CarrierConfig caller 桥接 |
| `06-rro-parser-cache.txt` | XML 顺序、raw MNC、CarrierConfig cache 是关键实现点 |

需要更高可信度时，应在自己的设备/ROM 上重新采集完整日志，而不是把本仓库的摘录
当作所有平台的普遍结论。
