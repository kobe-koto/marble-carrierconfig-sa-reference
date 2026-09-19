# marble / Evolution X CarrierConfig 5G SA reference

这是一次针对 Redmi Note 12 Turbo CN（`marble`）上 Evolution X Android 17
QPR1 的 5G SA 驻网问题调查、修复原型和维护者指引。

仓库内容已按可公开分享的标准脱敏：不含设备序列号、ICCID、IMSI、电话号码、
用户账户、IP 地址、精确小区标识、原始 ROM/MBN、完整原始日志、签名私钥或完整
厂商 CarrierConfig XML。

## 结论摘要

目标设备的手机硬件、SIM、RF、modem firmware 和当时启用的 commercial MBN
均能完成 5G SA 注册。直接阻塞点是：

1. 最终 CarrierConfig 将 SA 标记为可用，但又同时要求禁用 SA；
2. Qualcomm modem 当时被编程为 `NrConfig=1`（NSA-only）；
3. 将其改为 `NrConfig=0`（combined SA+NSA）后，设备立即完成 NR SA 注册；
4. 仅修改 CarrierConfig RRO 不会让该 ROM 自动重新调用 `setNrConfig(0)`。

因此参考方案由两层组成：

- **CarrierConfig RRO**：修正最终运营商策略；
- **privileged companion**：在最终 CarrierConfig 加载后，通过 Qualcomm
  `ExtTelephonyManager` 对符合条件的 slot 执行 query/set/verify。

实机冷启动测试验证了从 NSA-only 自动恢复到 combined，随后注册 NR SA，数据正常。

> 实测确认的是 SA 能力和 combined 模式。测试现场最终选择了 SA；未刻意屏蔽 SA
> 以强制完成一次独立的 NSA attach，因此不把“现场 NSA 驻网成功”列为已验证事实。

## 仓库结构

```text
companion/             privileged ExtTelephony applicator 源码
overlay/               CarrierConfig XML patcher 与提取工具
  input/               本地 ROM 输入，git 忽略
  tools/
docs/                  完整分析和维护者修复指引
evidence/              脱敏后的关键证据摘录
tests/                 patcher 的最小回归测试
build.sh               本地构建 RRO、companion 和模块 ZIP
```

## 文档入口

- [完整分析](docs/analysis.md)
- [架构与方案边界](docs/architecture.md)
- [ROM 维护者修复指引](docs/maintainer-fix-guide.md)
- [验证方法和结果](docs/validation.md)
- [脱敏说明](docs/privacy.md)
- [证据索引](evidence/README.md)

## 快速构建

依赖：`python3`、`javac`、`jar`、`aapt2`、`d8`、`zipalign`、
`apksigner`、`keytool`、`zip` 和 Android platform `android.jar`。

先从目标 ROM 的 `CarrierConfigResCommon.apk` 提取输入：

```bash
./overlay/tools/extract_vendor_xml.sh /path/to/CarrierConfigResCommon.apk
```

再构建：

```bash
./build.sh
```

生成的 `keys/`、`build/`、`dist/`、`reports/`、`variants/` 均不会提交到 Git。
构建脚本生成的本地测试证书不应被视为发布密钥。

## 两种策略

- `explicit-nsa`：只处理原 vendor XML 中明确声明 NSA availability 的 selector；
  推荐先使用。
- `universal`：将全局默认和现有相关 override 统一为 SA+NSA；可能覆盖运营商有意
  设置的认证、漫游、IMS、紧急呼叫或功耗限制。

CarrierConfig XML 不能动态探测“当前网络是否真的部署 NSA/SA”。所谓
`explicit-nsa` 是依据 ROM 内 vendor 配置的静态声明，不是实时网络检测。

## 安全边界

- 不修改 NV；
- 不替换 MBN；
- 不强制 VoNR；
- 不直接占用 QTI HAL callback；
- 不同时启用两个 RRO 变体；
- 完整 `vendor.xml` RRO 必须随 ROM/vendor 更新重新生成。

## License

Apache-2.0。厂商 ROM、CarrierConfig、Qualcomm 库和接口仍受其各自许可证约束；
本仓库不重新分发这些二进制或完整派生配置。
