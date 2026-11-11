# Moore 4c Custom GUI — Konke 面板自研固件发布仓

本仓库承载 **Konke Moore 4c 智能面板** 自研固件的 OTA 发布物。
完整源码见私有仓 `moore4c-src`。

## 当前固件

**v2.9.1-konke** — 语音-继电器桥接修复 + Web 控制台 cgi-bin 适配版

功能: 仪表盘 UI(fast takeover ~10s) · 米家云+本地中枢双通道 · GPIO 继电器 ·
触摸双协议 · WiFi 管理 · Web 控制台(:8080) · OTA 自更新 · 授权门禁

## 安装（一键脚本，推荐）

**要求**: macOS/Linux + expect + 设备与电脑同网段

```bash
git clone https://github.com/snailll2/Konke-Custom-GUI.git
cd Konke-Custom-GUI/install
./install.sh <设备IP>            # 例: ./install.sh 192.168.50.120
```

脚本自动完成: 资源检查 → payload 组装 → 上传 → md5 校验 → 幂等部署 →
启动验证（6 进程）。安装日志全程输出。

**默认不携带米家凭据**（干净安装）。如需连带部署凭据:

```bash
WITH_CREDS=1 ./install.sh <设备IP>
```

### ssh 登录方式

| 项 | 值 |
|---|---|
| 地址 | `root@<设备IP>` |
| 密码 | Konke 统一密码（脚本内置，无需手动输入）|
| 端口 | 22 |

```bash
ssh root@192.168.50.120          # 密码在提示时输入
```

### 安装后访问

| 服务 | 地址 |
|---|---|
| Web 控制台 | `http://<设备IP>:8080` |
| 米家状态 API | `http://<设备IP>:8080/cgi-bin/api.cgi?action=get_mijia_status` |
| 授权状态 | `.../api.cgi?action=get_license_status` |
| 设备日志 | ssh 后 `cat /tmp/m4c-boot.log /tmp/m4c-s1e.log` |

### 授权激活

1. 未授权设备开机屏幕显示激活页（含机器码 `XXXX-XXXX-XXXX-XXXX`）
2. Web 控制台打开也会弹出授权页（机器码 + 激活码输入）
3. 将机器码提供给供应商获取授权码，粘贴激活——**屏幕激活页自动消失**

### OTA 更新

设备自动检查 `version.json` → 有新版时提示 → 确认后下载安装重启。
已公开仓库，**无需任何 token**。

## 目录结构

```
├── README.md                          本文件
├── version.json                       OTA 版本清单（设备检查入口）
├── release/
│   └── s1e_custom_gui_latest.tar.gz   固件包（30 文件平铺，OTA 安装格式）
└── install/
    └── install.sh                     一键安装脚本
```

## 源码

完整源码（含米家模块、语音中继、授权体系、构建管线）:
`https://github.com/snailll2/moore4c-src`（私有，需授权访问）
