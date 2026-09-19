# CarrierConfig RRO generator

本目录不提交目标 ROM 的完整 `vendor.xml`。构建前应从**同一 ROM/vendor
版本**的 `CarrierConfigResCommon.apk` 提取：

```bash
./overlay/tools/extract_vendor_xml.sh /path/to/CarrierConfigResCommon.apk
```

也可手动执行：

```bash
aapt2 dump xmltree CarrierConfigResCommon.apk \
  --file res/xml/vendor.xml > overlay/input/vendor.xmltree
python3 overlay/tools/xmltree_to_xml.py \
  overlay/input/vendor.xmltree overlay/input/vendor.xml
```

然后在仓库根目录运行：

```bash
./build.sh
```

## 两种 patch 模式

- `explicit-nsa`：扫描原 XML 中明确包含 NR availability `1`（NSA）的
  selector，在文档末尾追加 SA+NSA override。
- `universal`：将无 selector 的默认块和现有 SA/NR 专用 override 规范化为
  SA+NSA，风险更高。

## 关键构建约束

`aapt2 link` 必须保留：

```text
--keep-raw-values
```

否则 `mnc="00"` 可能只剩编译后的整数 `0`，CarrierConfig 通过
`getAttributeValue()` 进行字符串匹配时将无法匹配两位 MNC。

RRO 替换的是完整 `res/xml/vendor.xml`，ROM/vendor 更新后必须重新提取和构建，
不可跨版本盲用。
