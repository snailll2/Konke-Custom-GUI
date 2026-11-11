# Moore 4c Custom GUI — Konke 面板自研固件发布仓

本仓库承载 **Konke Moore 4c 智能面板** 自研固件的 OTA 发布物与安装工具。

## 功能总览

| 模块 | 说明 |
|---|---|
| 🖥 仪表盘 | 60FPS DMA 渲染，时钟/天气/设备磁贴，左右滑页，下拉控制中心 |
| ⚡ 继电器 | 2 路本地继电器（触摸磁贴/语音/Web 三通道控制），带过温保护自动断电 |
| 🏠 米家全链路 | 云 MQTT + 本地中枢双通道，设备列表/实体自动发现，实时状态轮询 |
| 🎙 离线语音 | GX8002 芯片唤醒识别（"小K小K"），动作可劫持映射到 HA 实体 |
| 📶 WiFi 管理 | 扫描/连接/持久化，nl80211 驱动 |
| 🌐 Web 控制台 | :8080，布局编辑/实体绑定/系统设置/OTA/语音映射 |
| 🔐 授权门禁 | 机器码+Ed25519 签名激活，未激活全屏提示+接口只读 |
| 📡 OTA | 自动检查版本，确认后下载安装重启 |

## 屏幕预览

**主仪表盘**（时钟/天气/继电器磁贴/页面指示条）

![dashboard](screenshots/dash.png)

**未授权激活页**（开机自动显示，含本机访问地址，激活后自动消失）

![gate](screenshots/gate.png)

## 已知限制

- **按键音**：触摸/翻转的提示音代码链路完整（可配置开关），但 Konke 面板无 Aqara 蜂鸣器硬件节点，当前硬件静默。发声需走 CI1302 语音芯片（待语音链解冻后经原厂通道实现）。
- **语音反馈**：语音识别/播报依赖原厂 lua 链（当前冻结以独占屏幕）。冻结期间语音不可用；解冻方案（pty 中继）代码已就绪待验证。

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
    ├── install.sh                     一键安装脚本（Mac/Linux, 带 expect）
    └── device_install.sh              设备端脚本（ssh 进面板后直接跑）
```
