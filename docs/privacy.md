# 脱敏与发布说明

## 已移除或替换

- ADB serial；
- ICCID、IMSI、电话号码；
- 用户账户与应用数据；
- IPv4/IPv6 地址、接口地址和 DNS 详情；
- PCI、TAC、NCI、精确小区身份；
- 完整 NR-ARFCN（证据中只保留 band）；
- 精确时间线、进程号、Binder 地址和 token；
- 原始 ROM APK/JAR、MBN、数据库；
- 完整厂商 `vendor.xml`；
- 本地 APK 签名私钥和已签名发布产物。

## 保留的非个人技术信息

- 设备代号和 ROM 大版本；
- 运营商公共 MCC/MNC；
- NR band；
- CarrierConfig key/value；
- Qualcomm API/method 名；
- 成功/失败和状态转换；
- 模块/包名。

## 发布前建议

即使本仓库已脱敏，提交者仍应在公开托管前运行：

```bash
grep -RInaE '(ICCID|IMSI|serial|[0-9]{15,20}|[0-9a-f]{12,})' .
```

并人工检查 `git diff --cached`。不要提交 `overlay/input/vendor.xml`、`keys/`、
`dist/` 或新的原始日志。
