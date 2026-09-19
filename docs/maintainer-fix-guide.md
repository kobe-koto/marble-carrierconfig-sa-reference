# ROM 维护者修复指引

本页给出比 KernelSU/RRO workaround 更适合 ROM 源码树的修复方向。

## A. 修正 CarrierConfig 源数据

在生成 `CarrierConfigResCommon.apk` 的 device/vendor overlay 源码中搜索：

```text
carrier_sa_mode_available_bool
carrier_disable_sa_mode_bool
carrier_disable_vice_sa_mode_bool
carrier_nr_availabilities_int_array
```

针对确实支持 SA+NSA 的运营商 selector，最终有效值应保持一致：

```xml
<int-array name="carrier_nr_availabilities_int_array" num="2">
    <item value="1" />
    <item value="2" />
</int-array>
<boolean name="carrier_sa_mode_available_bool" value="true" />
<boolean name="carrier_disable_sa_mode_bool" value="false" />
<boolean name="carrier_disable_vice_sa_mode_bool" value="false" />
```

重点检查 XML 后部无 selector 默认块是否重新覆盖前面的运营商值。不要只看单个
MCC/MNC block，应验证 `dumpsys carrier_config` 中的**最终合并结果**。

若直接修 ROM 源码，应优先修源 CarrierConfig，而不是永久携带覆盖完整
`vendor.xml` 的 RRO。

## B. 补齐 CarrierConfig -> Qualcomm NrConfig 的运行时同步

只修 XML 不足以保证已运行 modem 从 NSA-only 切换到 combined。应在 QTI telephony
集成层增加 reconciliation controller。

推荐触发点：

- `CarrierConfigManager.ACTION_CARRIER_CONFIG_CHANGED`
- active subscription / SIM slot 变化
- radio/QTI service reconnect
- boot 完成后的最终 CarrierConfig 阶段

推荐流程：

1. 枚举活动订阅并取得 slot；
2. 读取该 subId 的最终 CarrierConfig；
3. 根据 availability 和 disable flags 计算 target；
4. 通过 `ExtTelephonyManager` 注册 callback/client；
5. `queryNrConfig(slot)`；
6. 当前值不同才 `setNrConfig(slot, target)`；
7. 回读并记录失败；
8. unregister callback、unbind service。

对于本问题至少需要映射：

```text
NSA + SA allowed -> NR_CONFIG_COMBINED_SA_NSA (0)
NSA only         -> NR_CONFIG_NSA (1)
SA only          -> NR_CONFIG_SA (2)
```

如果 policy 不完整、配置尚未加载或 slot 无活动订阅，应 no-op，而不是猜测。

## C. 推荐落点

优先选择已有 Qualcomm telephony 生命周期和 privileged 权限的组件，例如：

- vendor/QTI telephony integration package；或
- device-specific persistent `system_ext` telephony helper。

不建议把核心同步逻辑绑定在 Settings UI 开关中，因为：

- 无用户交互的 cold boot 也需要同步；
- SIM/CarrierConfig 动态刷新也需要同步；
- UI 进程不是可靠的 modem policy owner。

## D. 不要直接连接 QTI radio HAL

不要在另一个长期运行组件中直接实例化 `QtiRadioAidl`/`QtiRadioHidl` 并调用
`registerCallback()`。实测 direct probe 会改变 HAL callback ownership，需要重启
`com.qti.phone` 才能恢复。

应使用：

```text
ExtTelephonyManager -> com.qti.phone.ExtTelephonyService
```

并让现有 QTI phone process 继续拥有底层 HAL callback。

## E. 冷启动时序

脱敏日志证明同一次启动中可能先收到带通用默认值的广播，几秒后才出现运营商最终
配置。因此实现必须：

- 监听后续 `CARRIER_CONFIG_CHANGED`；
- 幂等；
- 对重复广播进行合并/去抖；
- 不因第一次“不合格”就永久停止本次启动的同步。

## F. 回归测试清单

1. 单 SIM、双 SIM；
2. 每个 slot 分别作为默认数据 SIM；
3. boot 前 modem 分别处于 0/1/2；
4. SIM 热切换/禁用启用；
5. CarrierConfig cache 已存在和已清空；
6. SA 覆盖区和仅 LTE/NSA 覆盖区；
7. 漫游、IMS、紧急呼叫基本回归；
8. `com.qti.phone` PID/callback 在同步过程中保持稳定；
9. 不满足 policy 的另一张 SIM 不被修改；
10. ROM OTA 后重新验证 CarrierConfig selector 和 QTI API 兼容性。

## G. 静态分析关键指向

本 ROM 中观察到的服务端链路：

```text
com.qti.phone.ExtTelephonyService.setNrConfig
com.qti.phone.ExtTelephonyServiceImpl.setNrConfig
com.qti.phone.QtiRadioProxy.setNrConfig
com.qti.phone.QtiRadioAidl.setNrConfig
vendor.qti.hardware.radio.qtiradio.IQtiRadio.setNrConfig
```

`TeleService.apk` 未发现对应 caller/vendor key 消费逻辑。维护者可从
`CarrierConfigChanged` 到上述 ExtTelephony API 之间的缺失桥接开始排查，而不必先
更换 MBN 或修改 RF 配置。
