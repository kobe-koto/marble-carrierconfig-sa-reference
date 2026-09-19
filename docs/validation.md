# 验证方法与结果

## 已验证

- CarrierConfig RRO 最终值正确；
- `mnc="00"` raw value 在二进制 XML 中保留；
- cache 清理后新配置被 phone process 读取；
- direct capability test 中 `NrConfig 1 -> 0` 成功；
- combined 后自动注册 NR SA；
- privileged companion 通过 ExtTelephony 完成 `query -> set -> verify`；
- companion 操作期间 `com.qti.phone` PID 不变；
- cold boot 从预置 NSA-only 自动恢复 combined；
- 不符合最终 CarrierConfig policy 的另一个活动 slot 未被修改；
- 数据连通正常。

## 未宣称已验证

- 独立的现场 NSA attach；
- Universal 变体在所有运营商的兼容性；
- VoNR；
- 紧急呼叫认证；
- 所有 Qualcomm 平台/ROM 版本；
- OTA 后无需重建完整 XML RRO。

## 推荐检查命令

```bash
adb shell dumpsys carrier_config
adb shell dumpsys telephony.registry
adb shell cmd overlay list
adb shell dumpsys package io.github.evox.carrierconfig.sa.enforcer
```

持久 applicator 日志（root）：

```bash
cat /data/user_de/0/io.github.evox.carrierconfig.sa.enforcer/files/nr-mode-enforcer.log
```

## 成功判据

```text
final CarrierConfig: [NSA, SA], SA enabled, disable flags false
initial NrConfig: 1 (test precondition)
set response: success
verified NrConfig: 0
registered RAT: NR_SA or network-appropriate combined behavior
data: connected
unrelated slot: unchanged
```
