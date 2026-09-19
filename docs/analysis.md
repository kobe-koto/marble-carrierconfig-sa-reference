# 完整分析报告

## 1. 测试范围

- 设备：Redmi Note 12 Turbo CN（`marble`）
- ROM：Evolution X Android 17 QPR1
- 运营商场景：中国移动 SIM，5G 已开通
- 目标：解释无法驻留 5G SA 的原因，并评估 NSA/SA policy 修复方案

所有设备唯一标识、SIM 唯一标识、账户、IP 和精确小区标识均已移除。

## 2. 初始观测

活动订阅的最终 CarrierConfig 出现矛盾组合：

```text
carrier_sa_mode_available_bool = true
carrier_disable_sa_mode_bool = true
carrier_disable_vice_sa_mode_bool = true
carrier_nr_availabilities_int_array = [1]
```

其中 availability `1` 表示 NSA。QTI HAL 同时报告：

```text
NrConfig = 1   # NSA-only
EN-DC = true
```

这说明用户层允许 5G 并不等价于 modem 已允许 SA。

## 3. 能力隔离实验

在不更换 MBN、不写 NV、不改变 allowed-network-types mask 的条件下，将目标 slot
临时从：

```text
NrConfig = 1   # NSA-only
```

切换为：

```text
NrConfig = 0   # combined SA+NSA
```

set response 成功，连续回读均为 `0`。随后设备自动注册 NR SA，语音/数据注册均
in service，移动数据可用。

这足以证明在测试条件下：

- 设备 RF 与 modem 支持目标 SA 网络；
- SIM/套餐不是直接阻塞点；
- 当前 commercial MBN 并未阻止完成 SA 注册；
- 直接软件阻塞点是 NR mode 被设为 NSA-only。

它不证明所有地点、所有运营商或所有 MBN 都没有问题。

## 4. CarrierConfig RRO 实现中的三个陷阱

### 4.1 XML 合并顺序

该 ROM 的 CarrierConfig 解析按 XML 文档顺序把匹配块合并进
`PersistableBundle`。早期 MCC/MNC 块之后仍存在无 selector 的默认块，会再次把
SA disable flags 写回 `true`。

因此保守模式不能只原地修改早期块；它必须：

1. 从原始 XML 扫描明确包含 NSA availability `1` 的 selector；
2. 在整个 XML 末尾追加对应 override；
3. 让最终匹配块最后写入 SA+NSA 值。

### 4.2 两位 MNC 的 raw value

如果 `aapt2 link` 未使用：

```text
--keep-raw-values
```

`mnc="00"` 可能只剩编译后的整数 `0`，raw string 丢失。CarrierConfig selector
通过字符串形式读取属性时，`"0"` 无法匹配 `"00"`。

正确二进制 XML dump 应包含：

```text
mnc=0 (Raw: "00")
```

### 4.3 CarrierConfig cache

缓存位于 phone process 的 device-encrypted data 中，并以默认 CarrierConfig app
版本等信息作为复用依据。RRO 不会改变目标 app 的 versionCode，所以安装 RRO 后
仍可能继续读取旧缓存。

模块必须在启用启动和卸载时清除对应 CarrierConfig cache，使其重新解析资源。

## 5. 为什么纯 RRO 仍不够

RRO 生效后，最终 CarrierConfig 已变为：

```text
carrier_sa_mode_available_bool = true
carrier_disable_sa_mode_bool = false
carrier_disable_vice_sa_mode_bool = false
carrier_nr_availabilities_int_array = [1, 2]
```

但 QTI HAL 仍可继续报告 `NrConfig=1`，说明该 ROM 没有在 CarrierConfig
刷新/启动后把既存 modem state 重新编程为 combined。

静态分析得到：

- `TeleService.apk` 中没有 `setNrConfig` 调用和上述 vendor key；
- `QtiTelephony.apk` 提供完整的服务端调用链，但主要是被动 API；
- 未发现 ROM 内有组件把这些 CarrierConfig key 映射为 `setNrConfig(0)`。

服务端链路为：

```text
ExtTelephonyService.setNrConfig
  -> ExtTelephonyServiceImpl.setNrConfig
  -> QtiRadioProxy.setNrConfig
  -> QtiRadioAidl/QtiRadioHidl.setNrConfig
  -> vendor.qti.hardware.radio.qtiradio.IQtiRadio.setNrConfig
```

所以 policy 和 modem runtime state 在本 ROM 上发生了脱节。

## 6. 参考修复

参考 companion 是一个 privileged `system_ext` app。它在 boot 和
`CARRIER_CONFIG_CHANGED` 时读取**最终合并后的**每个活动订阅配置，并只选择：

```text
NR availability 同时包含 NSA(1) 和 SA(2)
SA available = true
disable SA = false
disable vice SA = false
```

的 slot。随后通过 `ExtTelephonyManager`：

```text
query current -> set combined if needed -> verify
```

它不直接构造 `QtiRadioAidl/Hidl`。直接 HAL probe 会注册新的 callback，可能替换
`com.qti.phone` 原有 callback；正式方案必须保持 callback ownership。

## 7. 冷启动竞态

持久日志显示，早期 boot 广播到达时 CarrierConfig 可能仍是通用/禁用 SA 的临时
状态。reference implementation 会安全地 no-op；随后收到最终
`CARRIER_CONFIG_CHANGED` 后再选择 slot 并执行设置。

因此 ROM 级修复不应只在最早的 boot 回调执行一次。必须：

- 监听最终 CarrierConfig 变化；
- 支持订阅/SIM 切换；
- query-before-set；
- 幂等；
- debounce/coalesce 重复广播；
- 对每个 slot 单独处理并回读确认。

## 8. 最终验证结论

在冷启动测试中，测试前人为将目标 slot 恢复为 NSA-only，随后直接重启。最终
CarrierConfig 加载后，companion 记录：

```text
initial query = 1
set combined = success
verify query = 0
```

之后设备自动注册 NR SA，数据连接成功。另一个不满足最终 policy 的活动 slot
保持排除。
