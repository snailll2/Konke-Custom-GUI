# Konke-Custom-GUI — Moore 4c 面板固件发布仓

本仓库只承载 OTA 发布物；完整源码见 **snailll2/moore4c-src**（私有）。

## OTA 端点
- 版本清单: `version.json`（设备开机/定时检查）
- 固件包: `release/s1e_custom_gui_latest.tar.gz`

## 发布流程
1. 源码仓提交/构建 → 生成新 tar 包
2. 更新 `version.json`（version_code 递增 + tarball_size_bytes 与包一致）
3. 本仓提交推送即完成发布
