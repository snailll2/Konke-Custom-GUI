#!/bin/sh
# ============================================================================
# device_install.sh — Moore 4c 面板 SSH 登录后的一键下载安装/修复脚本
# 用法: ssh root@<设备IP> 后执行:  sh /tmp/device_install.sh
#   或本机直接:                    curl -ksf http://<电脑IP>/device_install.sh | sh
# 功能: 依赖检查 → 从 OTA 仓拉固件包 → 幂等部署(含 /data/www web 副本) →
#       授权迁移 → 启动 → 进程验证
# ============================================================================
set -u

BASE=/data/moore4c
REL=/data/scripts
OTA_HOST="raw.githubusercontent.com"
OTA_PATH="/snailll2/Konke-Custom-GUI/main/release/s1e_custom_gui_latest.tar.gz"
OTA_URL="https://${OTA_HOST}${OTA_PATH}"
PKG=/tmp/m4c_install_pkg.tar.gz

say() { echo "[device-install] $*"; }
fail() { echo "[安装失败] $*"; exit 1; }

# ---------- 0. 环境检查 ----------
say "环境检查..."
[ -x /bin/busybox ] || fail "不是 Konke Moore 4c 面板(busybox 缺失)"
FREE_KB=$(df -k /data 2>/dev/null | tail -1 | awk '{print $4}')
[ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 61440 ] && fail "/data 空间不足(${FREE_KB}KB < 60MB)"
say "  /data 可用 ${FREE_KB}KB ✓"

FETCH="curl -skf -m 120 -o"
HAVE_CURL=0
[ -x /data/moore4c/bin/curl ] && { FETCH="/data/moore4c/bin/curl -skf -m 120 -o"; HAVE_CURL=1; }
command -v curl >/dev/null 2>&1 && { FETCH="curl -skf -m 120 -o"; HAVE_CURL=1; }
if [ "$HAVE_CURL" != "1" ]; then
  # 兜底: 固件自带 fetch_https.sh(raw.githubusercontent 可直连时)
  [ -x $REL/fetch_https.sh ] && { FETCH="__FETCH_HTTPS__"; HAVE_CURL=1; }
fi
[ "$HAVE_CURL" = "1" ] || fail "需要 curl(面板自带或系统)或 $REL/fetch_https.sh"
say "  下载器就绪 ✓"

# ---------- 1. 下载固件包(多镜像回退: 国内 CDN 优先, raw 兜底) ----------
say "下载固件包 v$(grep -o '"version": *"[^"]*"' $REL/version.json 2>/dev/null | cut -d'"' -f4) ..."
rm -f "$PKG"
MIRRORS="\
ghfast.top/https://raw.githubusercontent.com/snailll2/Konke-Custom-GUI/main/release/s1e_custom_gui_latest.tar.gz \
gh-proxy.org/https://raw.githubusercontent.com/snailll2/Konke-Custom-GUI/main/release/s1e_custom_gui_latest.tar.gz \
cdn.jsdelivr.net/gh/snailll2/Konke-Custom-GUI@main/release/s1e_custom_gui_latest.tar.gz \
https://raw.githubusercontent.com/snailll2/Konke-Custom-GUI/main/release/s1e_custom_gui_latest.tar.gz"
if [ "$FETCH" = "__FETCH_HTTPS__" ]; then
  $REL/fetch_https.sh "$OTA_HOST" "$OTA_PATH" "$PKG" 120
else
  for u in $MIRRORS; do
    say "  try: $u"
    rm -f "$PKG"
    $FETCH "$PKG" "$u" && [ -s "$PKG" ] && break
  done
fi
[ -s "$PKG" ] || fail "固件包下载失败(检查网络)"
tar -tzf "$PKG" >/dev/null 2>&1 || fail "固件包损坏"
say "  固件包就绪 ($(du -k "$PKG" | cut -f1)KB) ✓"

# ---------- 2. 停止运行中的组件 ----------
say "停止运行中的组件..."
for n in s1e_standalone_app_konke property_service ubusd miio_agent sysservice; do
  kill -9 $(ps | grep "$n" | grep -v grep | awk '{print $1}') 2>/dev/null
done
kill -9 $(ps | grep "httpd -p 8080" | grep -v grep | awk '{print $1}') 2>/dev/null
sleep 1

# ---------- 3. 覆盖式部署 (包内同名覆盖, 其余保留; 只有卸载才清空) ----------
say "部署固件..."
mkdir -p $BASE/bin $BASE/lib $BASE/res $REL /data/www/cgi-bin /etc/config/intercom
# 走 staging + 用户配置保护(与 OTA 安装逻辑一致): 设备已有的配置永不被包覆盖
OTA_DIR=$BASE/ota
mkdir -p $OTA_DIR/staging
tar -xzf "$PKG" -C $OTA_DIR/staging/ || fail "固件包解压失败"
# 用户数据默认文件保护清单: 与包内实际存在的默认配置一一对应
for CFG in layout_p0.json sys_settings.json ha_config.json ha_cards.json switch_config.json voice_map.json; do
    [ -f "$REL/$CFG" ] && rm -f "$OTA_DIR/staging/$CFG"
done
# 主题升级: 先解到 .aqgui_new 再原子替换, 解压失败保留旧主题
mkdir -p /usr/share && rm -rf /usr/share/.aqgui_new && mkdir -p /usr/share/.aqgui_new
tar -xzf $OTA_DIR/staging/aqgui_theme.tgz -C /usr/share/.aqgui_new/ && {
  rm -rf /usr/share/aqgui && mv /usr/share/.aqgui_new/aqgui /usr/share/aqgui
}
rm -rf /usr/share/.aqgui_new; rm -f $OTA_DIR/staging/aqgui_theme.tgz; rm -f /data/scripts/aqgui_theme.tgz
cp -f $OTA_DIR/staging/* $REL/ 2>/dev/null
rm -rf $OTA_DIR
cp -f $REL/s1e_standalone_app_konke $BASE/bin/ 2>/dev/null
cp -f $REL/relay.sh $BASE/bin/ 2>/dev/null
# web 控制台在线副本: v12+ docroot=/data/www(start.sh), /tmp/www 已废弃不分发
cp -f $REL/index.html /data/www/index.html 2>/dev/null
cp -f $REL/api.cgi    /data/www/cgi-bin/api.cgi 2>/dev/null

# ---------- 4. 权限与授权迁移 ----------
chmod 755 $BASE/bin/* $REL/api.cgi $REL/relay.sh $REL/do_ota.sh \
         $REL/fetch_https.sh $REL/http_body_strip 2>/dev/null
chmod 644 $REL/*.json $REL/*.bin $REL/index.html 2>/dev/null
# 授权迁移(旧 overlay 路径 → /data 持久层; 定版 /data/scripts/license.json)
for OLD in /etc/config/intercom/license.json /data/moore4c/license.json; do
  if [ -s "$OLD" ] && [ ! -s /data/scripts/license.json ]; then
    cp -f "$OLD" /data/scripts/license.json
    say "  授权已迁移到 /data/scripts/license.json ✓"
  fi
done

# ---------- 5. 启动 ----------
say "启动服务栈..."
sh $BASE/start.sh >/tmp/m4c-boot.log 2>&1
sleep 8

# ---------- 6. 验证 ----------
say "验证..."
OK=0
for n in s1e_standalone_app_konke property_service ubusd miio_agent; do
  ps | grep -q "$n" && OK=$((OK+1))
done
say "  存活进程: $OK/4"
if [ "$OK" -ge 3 ]; then
  say "✅ 安装完成"
  IP=$(ifconfig wlan0 2>/dev/null | grep -o 'addr:[0-9.]*' | cut -d: -f2)
  [ -z "$IP" ] && IP=$(ifconfig eth0 2>/dev/null | grep -o 'addr:[0-9.]*' | cut -d: -f2)
  say "   Web 控制台: http://${IP:-<面板IP>}:8080"
  say "   授权状态:   http://${IP:-<面板IP>}:8080/cgi-bin/api.cgi?action=get_license_status"
  say "   设备日志:   /tmp/m4c-boot.log /tmp/m4c-s1e.log"
else
  fail "进程缺失, 排查: cat /tmp/m4c-boot.log /tmp/m4c-s1e.log"
fi
rm -f "$PKG"
