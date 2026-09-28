# 5G SA/NSA CarrierConfig Troubleshooting and Porting Guide

本指南面向三类读者：

- 在其他设备上排查“5G SA 无法驻网”的用户或 Agent；
- 将本参考实现移植到其他 Qualcomm 设备或 ROM 的开发者；
- 希望从 ROM 源码根治问题的 Maintainer。

本指南描述的是一种**分层排查方法**，不是所有 Android 设备通用的补丁。5G
驻网同时受 framework policy、modem runtime state、MBN/固件、SIM/套餐、网络
覆盖和频段组合影响。必须先定位故障层，再决定是否修改 CarrierConfig 或 modem
状态。

## 1. 先明确要证明什么

“设置里显示 5G”或“NR 开关存在”不能证明 SA 可用。至少要分别回答以下问题：

1. 最终生效的 CarrierConfig 是否允许 SA？
2. modem 当前的 NR mode 是否为 NSA-only、SA-only 或 combined？
3. 把 runtime mode 改为 combined 后，设置是否成功并保持？
4. combined 后，网络是否实际完成 SA 注册？
5. 数据、IMS、语音和另一张 SIM 是否仍然正常？

其中第 3 项是很有价值的能力隔离实验，但不是长期修复。它只在目标
CarrierConfig 已明确允许 SA、并且设备处于可回滚的测试环境时进行。

## 2. 故障模型

建议把问题分成四层，而不是笼统称为“5G 不工作”：

| 层 | 典型证据 | 常见修复方向 |
|---|---|---|
| Policy | `carrier_sa_mode_available_bool`、disable flags、NR availability 不一致 | 修正 ROM 的 CarrierConfig 源数据或 RRO |
| Runtime state | policy 已允许 SA，但 Qualcomm `NrConfig` 仍为 NSA-only | 增加 CarrierConfig 到 QTI API 的 reconciliation |
| Modem capability | `setNrConfig` 失败、回读不变或服务不存在 | 检查平台、MBN、固件、权限和厂商 API |
| Network | mode 已 combined，但仍只注册 LTE/NSA 或无数据 | 检查覆盖、频段、套餐、漫游、认证、IMS 和网络侧配置 |

本次参考设备属于前两层：CarrierConfig 自相矛盾，且 ROM 没有把最终 policy
同步到 Qualcomm modem。不能据此断言所有设备都存在同一缺陷。

## 3. 最小安全证据集

先采集基线，再做改变。命令名称会随 Android 版本变化；找不到某条命令时保留
失败记录，不要用猜测填补结果。

```bash
adb shell getprop ro.product.board
adb shell getprop ro.hardware
adb shell getprop ro.boot.hardware
adb shell getprop ro.build.version.release
adb shell dumpsys carrier_config
adb shell dumpsys telephony.registry
adb shell cmd overlay list
adb shell dumpsys package com.android.carrierconfig
adb shell dumpsys package com.qti.phone
```

还应记录：

- 活动订阅对应的 slot，而不是只记录电话号或 SIM 顺序；
- 当前 RAT、注册状态、是否有数据连接；
- modem/MBN 版本和是否刚发生 OTA；
- 双 SIM 时每个 slot 的 policy 和 runtime 状态。

公开报告中应删除设备序列号、ICCID、IMSI、电话号码、IP、完整小区标识、精确
时间线、PID、Binder token 和完整原始厂商 XML。只保留足以支持结论的 key/value、
状态转换、公共 MCC/MNC、band 和错误码。

## 4. 读取 CarrierConfig 的判定规则

对每个活动 subscription，读取**最终合并后的**配置，而不是只看 XML 中某个
MCC/MNC block。对本参考实现，只有以下组合才把 slot 视为允许 SA+NSA：

```text
carrier_nr_availabilities_int_array contains 1 and 2
carrier_sa_mode_available_bool = true
carrier_disable_sa_mode_bool = false
carrier_disable_vice_sa_mode_bool = false
```

通常可作如下判断：

- 缺少 SA availability、SA available 为 false，或任一 disable flag 为 true：
  不应自动写入 combined mode；先确认这是有意策略还是 ROM 配置错误。
- 只包含 `1`：配置只声明 NSA，不足以证明可以安全打开 SA。
- 同时包含 `1` 和 `2`，且 disable flags 正确：policy 层允许 SA，但仍不证明
  modem、网络或套餐一定支持 SA。

这些 key 的语义和数值必须在目标 ROM/QTI 实现中确认。不要假定非 Qualcomm
平台或其他厂商 ROM 使用相同枚举。

### XML 特有陷阱

CarrierConfig vendor XML 可能按文档顺序将多个匹配 block 合并到同一个
`PersistableBundle`。后面的无 selector 默认 block 可能覆盖早期的运营商 block。
因此应检查最终 `dumpsys carrier_config`，而不是只修改第一个匹配节点。

如果用 RRO 替换 `res/xml/vendor.xml`：

1. 输入必须来自目标 ROM/vendor 的同一版本 `CarrierConfigResCommon.apk`；
2. `explicit` 策略应只处理原文件明确声明 NSA 的 selector；
3. 需要覆盖后置默认 block 时，应在文档末尾追加最终 selector override；
4. 编译二进制 XML 时保留 raw values，尤其是两位 MNC，例如 `"00"`；
5. 由于 RRO 不改变默认 CarrierConfig app 的 versionCode，应清理
   CarrierConfig cache 并重启验证。

完整 `vendor.xml` RRO 是版本绑定的产物。ROM/vendor 更新后必须重新提取、重新
构建和重新验证，不能跨版本盲用。

## 5. 区分 policy 问题和 runtime 问题

### 5.1 Policy 不正确

如果最终配置类似以下矛盾组合：

```text
SA available = true
disable SA = true
disable vice SA = true
NR availability = [1]
```

先修 CarrierConfig 源数据或 RRO。此时不要先改 MBN、写 NV 或锁定频段。

### 5.2 Policy 正确但 modem 仍为 NSA-only

如果最终配置已经是：

```text
SA available = true
disable SA = false
disable vice SA = false
NR availability = [1, 2]
```

而 modem 查询仍返回 NSA-only，那么 RRO 只修复了 policy，未修复 runtime state。
在 Qualcomm 实现中，应检查是否存在等价于以下流程的调用者：

```text
CarrierConfig changed
    -> read final config for each active subscription
    -> map policy to target NrConfig
    -> query current mode
    -> set only when different
    -> query again and verify
```

本参考实现使用的映射是：

```text
SA + NSA allowed -> 0 (combined)
NSA only         -> 1
SA only          -> 2
```

该映射只适用于已确认采用相同 Qualcomm API/枚举的实现。

### 5.3 combined 设置成功但仍无 SA

这说明 policy 和至少一部分 modem runtime state 已经通过，剩余问题可能在：

- 当前地点没有 SA 覆盖；
- 目标频段或频段组合不匹配；
- SIM/套餐未开通对应 SA；
- MBN、运营商认证或网络侧能力不匹配；
- 漫游策略、IMS 或数据配置；
- modem/固件自身 bug。

此时不要把“没有 SA 注册”反推为 CarrierConfig 一定错误。应在已知 SA 覆盖、
已知可用 SIM 和多个时间点重复测试，并保留 LTE/NSA 回退行为。

## 6. 可迁移性判定

### A. Qualcomm + 相近 QTI 栈

这是最有希望复用的目标。确认以下条件：

- ROM 中存在 `com.qti.extphone.extphonelib` 或等价库；
- `com.qti.phone` 提供 ExtTelephony Binder 服务；
- API 具备 query/set NR config 能力；
- 应用可以获得对应 privileged/vendor 权限；
- `NrConfig` 的枚举值和 callback 行为已在目标设备上确认；
- 当前 `com.qti.phone` 继续拥有底层 HAL callback。

API 名称相似不等于 ABI 兼容。应从目标 ROM 的 jar、服务实现或公开 stub 中核对
方法签名、参数顺序、slot 语义、返回状态和回调生命周期。

### B. Qualcomm 但 API 或权限不同

可以移植设计，但通常不能直接安装 APK。需要修改：

- 编译 stub 和运行时 uses-library；
- package/permission/privapp allowlist；
- AIDL/HIDL 适配层；
- `NrConfig` 值到目标平台的映射；
- 连接、注册 callback、超时和服务重连逻辑。

如果只能直接访问 QTI HAL，先确认 callback ownership。一个新的长期 HAL client
可能替换 `com.qti.phone` 的 callback，导致电话栈异常。优先复用已有 ExtTelephony
服务；只有在理解 callback 管理并能做完整回归时才直接访问 HAL。

### C. 非 Qualcomm 或无 ExtTelephony

当前 companion 不适用。可复用的只有排查框架：先读最终 CarrierConfig，再寻找
厂商自己的 NR mode controller、modem service 或 framework bridge。不要把
`setNrConfig(0)`、权限名或 QTI package 名移植到 MediaTek、Samsung modem 或
完全不同的 Android telephony 栈。

## 7. Companion/ROM 修复的正确落点

### 临时验证或低风险测试模块

可采用 privileged `system_ext` companion，但必须满足：

- 只处理活动 subscription；
- 每个 slot 独立判定；
- policy 不完整或尚未加载时 no-op；
- 先 query、仅在需要时 set、再 query verify；
- 监听 `CARRIER_CONFIG_CHANGED`、SIM/subscription 变化、boot 和服务重连；
- 对重复广播去抖，支持超时和清理 callback；
- 记录脱敏的阶段、slot、状态码和结果；
- 不满足 policy 的另一张 SIM 不得被修改。

不能只在 Settings UI 开关中实现，因为 cold boot、SIM 切换和 CarrierConfig 动态
刷新都可能在没有用户交互时发生。

### Maintainer 的长期修复

推荐按以下优先级处理：

1. **修正 CarrierConfig 源数据**：确保真正支持 SA+NSA 的 selector 最终输出
   一致的 availability 和 disable flags，并移除会覆盖它的错误默认 block。
2. **补齐运行时桥接**：在已有 QTI telephony 生命周期中，把最终 CarrierConfig
   映射到 `NrConfig`，而不是依赖第三方常驻 APK。
3. **保持 HAL callback ownership**：通过现有 ExtTelephony 服务调用，避免另起
   client 直接抢占底层 callback。
4. **处理时序**：早期 boot 广播可能只有临时默认值；必须等待最终
   `CARRIER_CONFIG_CHANGED`，并允许后续重试。
5. **增加可观测性**：记录 policy、目标 slot、旧值、新值、状态码和 verify
   结果，但不要记录 IMSI/ICCID/完整小区信息。

本参考 ROM 中值得优先搜索的调用链为：

```text
CarrierConfigChanged
  -> policy reader
  -> ExtTelephonyService.setNrConfig
  -> ExtTelephonyServiceImpl.setNrConfig
  -> QtiRadioProxy.setNrConfig
  -> QtiRadioAidl/QtiRadioHidl.setNrConfig
  -> vendor.qti.hardware.radio.qtiradio.IQtiRadio.setNrConfig
```

如果服务端链路存在、但没有从 CarrierConfig 变化到该链路的 caller，这通常比
更换 MBN 或修改 RF 参数更值得先修。

## 8. 推荐实验顺序

在非主力设备上，建议按以下顺序执行，每一步都保留前后状态：

1. 记录设备、ROM、modem、活动 subscription 和最终 CarrierConfig。
2. 确认当前网络/套餐确实是要测试的 SA 场景，并记录当前 RAT。
3. 查找目标平台的 query/set NR mode 接口和权限，不要先假定 QTI 枚举。
4. 只对 policy 明确允许 SA 的 slot 做一次可回滚的 runtime mode 实验。
5. 回读确认 set 结果，观察是否自动重注册，以及 `com.qti.phone` 是否稳定。
6. 测试数据、IMS、语音、LTE/NSA 回退和另一 slot。
7. 冷启动前将 runtime mode 设为已知初始值，确认 ROM 是否会自动恢复。
8. 只有实验重复证明是 policy/runtime bridge 缺失时，才制作 RRO 或 companion。

不要把以下动作作为第一步：写 NV、替换 MBN、修改 PDC profile、锁频段、强制
VoNR 或关闭所有网络回退。它们会扩大变量，且可能掩盖真正的 framework 集成
问题。

## 9. 回归测试清单

### 设备与订阅

- 单 SIM 和双 SIM；
- 每个 slot 分别作为默认数据 SIM；
- SIM 热插拔、启用/禁用和重新选择默认数据卡；
- 一张符合 policy、另一张不符合 policy 的组合；
- 冷启动、热重启、airplane mode 切换。

### modem 与网络

- boot 前 runtime mode 为 0、1、2；
- SA 覆盖区和仅 LTE/NSA 覆盖区；
- 数据连接、IMS、语音、紧急呼叫基本回归；
- 漫游和不同网络制式回退；
- MBN/firmware 更新后重新验证。

### 系统稳定性

- CarrierConfig cache 已存在和已清除；
- `com.qti.phone` 进程及其服务连接保持稳定；
- 重复广播不会产生并发 set；
- set 失败、服务断开和 verify 不一致时有明确日志且不会死循环；
- 卸载或禁用修改后可恢复 stock CarrierConfig 和 stock runtime 行为。

## 10. 给其他 Agent/Maintainer 的报告模板

提交问题或移植补丁时，至少提供以下脱敏信息：

```text
Device/board:
Android/ROM build:
Modem/vendor stack:
SIM scenario: single or dual SIM, slot only
CarrierConfig final keys:
Current RAT/registration:
Current NrConfig, if available:
Query/set/verify result:
Cold-boot result:
Data/IMS/voice result:
Relevant service/package/API names:
```

报告应明确标注“已观察”“已实验验证”和“推测”，不要把单地点、单运营商、单
固件版本的结果写成平台普遍结论。

## 11. 不应从本指南推断的结论

- RRO 能自动让所有设备获得 SA；
- `carrier_sa_mode_available_bool=true` 等于网络已部署 SA；
- `NrConfig=0` 成功等于必然完成 SA attach；
- universal overlay 对所有运营商都是安全的；
- 不同 Qualcomm 世代、Android 版本或 QTI API 共享同一 ABI；
- SA 驻网失败必然需要 MBN、NV 或 RF 修改。

本仓库的具体实现、证据和当前设备验证结果仍以 [analysis.md](analysis.md)、
[architecture.md](architecture.md) 和 [validation.md](validation.md) 为准。
