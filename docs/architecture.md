# 架构与方案边界

## 数据流

```text
CarrierConfigResCommon.apk / res/xml/vendor.xml
             |
             v
      XML patch generator
             |
             v
   static vendor RRO APK
             |
             v
 final merged CarrierConfig per subscription
             |
             v
 privileged policy applicator
             |
             v
 Qualcomm ExtTelephonyManager Binder API
             |
             v
  query/set/verify modem NrConfig
```

## NrConfig 值

在本次 Qualcomm 实现中：

```text
0 = combined SA+NSA
1 = NSA-only
2 = SA-only
```

## 为什么由最终 CarrierConfig 决定 slot

companion 不硬编码“中国移动”或固定 MCC/MNC。RRO 决定 policy，companion 只消费
最终 policy。这样：

- `explicit-nsa` 和 `universal` 共用同一 applicator；
- 多 SIM 时每个 slot 单独判定；
- 运营商 selector 逻辑仍留在 CarrierConfig 层；
- app 不需要复制完整 carrier matching 规则。

## 纯 RRO 与模块 ZIP 的区别

纯 RRO APK：

- 修改 policy；
- 不保证当前 modem state 被重新设置。

模块 ZIP：

- 安装 RRO；
- 清理 CarrierConfig cache；
- 安装 privileged applicator；
- 在合适时机同步 modem state。

## 不在范围内

- VoNR 强制开启；
- NR band lock；
- MBN/PDC 修改；
- NV 写入；
- 运营商网络认证绕过；
- 对所有 Qualcomm 平台保证相同 API/枚举。
