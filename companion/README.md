# Qualcomm NR mode enforcer

这是一个 reference implementation，用于弥补“CarrierConfig 已更新，但 Qualcomm
modem 的现存 `NrConfig` 未被重新编程”的问题。

它是 privileged `system_ext` 应用，监听：

- `LOCKED_BOOT_COMPLETED`
- `BOOT_COMPLETED`
- `android.telephony.action.CARRIER_CONFIG_CHANGED`

对于每个活动订阅，仅当最终 CarrierConfig 同时满足以下条件时才选择该 slot：

```text
carrier_nr_availabilities_int_array contains 1 and 2
carrier_sa_mode_available_bool = true
carrier_disable_sa_mode_bool = false
carrier_disable_vice_sa_mode_bool = false
```

随后通过 `ExtTelephonyManager` 执行幂等流程：

```text
queryNrConfig -> setNrConfig(COMBINED) if needed -> queryNrConfig verify
```

## 为什么不直接实例化 QtiRadioAidl/HIDL

直接连接 vendor QTI radio HAL 会注册新的 HAL callback，可能替换
`com.qti.phone` 已持有的 callback。reference implementation 只通过公开的
ExtTelephony Binder 服务调用，避免破坏 callback ownership。

## 权限/库依赖

- `android.permission.READ_PRIVILEGED_PHONE_STATE`
- `android.permission.MODIFY_PHONE_STATE`
- `com.qualcomm.qti.permission.USE_EXT_TELEPHONY_SERVICE`
- `com.qti.extphone.extphonelib`

`stubs/` 只用于主机端 `javac` 编译；APK 运行时使用 ROM 自带的
`extphonelib.jar`，stub class 不会打包进 APK。
