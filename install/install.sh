#!/bin/bash
# ============================================================================
# moore4c 一键安装脚本 — Konke Moore 4c 面板
# 用法: ./install.sh <设备IP>
# 例:   ./install.sh 192.168.50.212
# 依赖: expect (macOS 自带 ssh/scp); Konke 统一 root 密码
# 流程: 本地组装 payload → 上传(/tmp, md5 校验) → 远程部署 → 启动 → 验证
# ============================================================================
set -u

IP="${1:-}"
[ -z "$IP" ] && { echo "用法: $0 <设备IP>   例: $0 192.168.50.212"; exit 1; }

PW="p9z34c"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/moore4c-ssh/known_hosts -o ConnectTimeout=10"

BASE=/tmp/moore4c-ssh
# WS = 本项目工作区 (assets/credentials, data/scripts 均从此取)
WS="$(cd "$(dirname "$0")/../.." && pwd)"
[ -d "$WS/assets/stage" ] || WS=/Users/snail/WORK/IOT/moore4c   # 存档副本运行时回退
STAGE=$WS/assets/stage                 # 修复过的 lib(symlink 正确) + bin 白名单
SCRIPTS=$WS/data/scripts
CRED=$WS/assets/credentials            # 米家凭据缓存(取自 163)
MIJIA_JSON=$WS/assets/credentials/mijia_restored.json   # OAuth 主凭据
INS=$BASE/installer
PAY=$INS/payload

fail() { echo "[安装失败] $*"; exit 1; }
say()  { echo "[moore4c-install] $*"; }

# ---------- 0. 本地资源检查 ----------
say "检查本地资源..."
for f in "$STAGE/bin/busybox" "$STAGE/bin/sysservice" "$STAGE/bin/ubusd" \
         "$STAGE/bin/ubus" "$STAGE/bin/miio_agent" "$STAGE/bin/property_service" \
         "$STAGE/bin/wpa_cli" \
         "$SCRIPTS/s1e_standalone_app_konke" "$SCRIPTS/relay.sh" \
         "$SCRIPTS/index.html" "$SCRIPTS/api.cgi" \
         "$SCRIPTS/opposans_ui_subset.ttf" \
         "$CRED/mijia_ca.cert" "$CRED/mips_26705031.key" "$CRED/mips_26705031.cert" \
         "$MIJIA_JSON"; do
  [ -f "$f" ] || fail "缺少资源: $f"
done

# ---------- expect 助手 ----------
mkdir -p "$PAY"
cat > "$INS/scp.exp" <<EOF
#!/usr/bin/expect -f
set timeout 600
set lf [lindex \$argv 0]
set rf [lindex \$argv 1]
spawn scp -O $SSH_OPTS \$lf root@$IP:\$rf
expect {
  -re "(?i)password:" { send "$PW\r"; exp_continue }
  eof
}
EOF
cat > "$INS/sshrun.exp" <<EOF
#!/usr/bin/expect -f
set timeout 600
set cmd [lindex \$argv 0]
spawn ssh $SSH_OPTS root@$IP \$cmd
expect {
  -re "(?i)password:" { send "$PW\r"; exp_continue }
  eof
}
catch wait result
exit [lindex \$result 3]
EOF
chmod +x "$INS/scp.exp" "$INS/sshrun.exp"

# ---------- 1. ping 检查 ----------
say "ping $IP ..."
ping -c 2 -t 3 "$IP" >/dev/null 2>&1 || fail "设备不可达: $IP"

# ---------- 2. 组装 payload ----------
say "组装 payload..."
rm -rf "$PAY"
mkdir -p "$PAY/root/moore4c/bin" "$PAY/root/moore4c/lib" "$PAY/root/moore4c/res" \
         "$PAY/scripts" "$PAY/www" "$PAY/cred" "$PAY/init.d"

# 2a. bin(白名单真文件+全部 symlink) + lib(依赖闭包白名单) — 2026-11-08 瘦身版
BIN_KEEP="busybox property_service ubusd ubus miio_agent sysservice s1e_standalone_app_konke relay.sh wpa_cli wpa_supplicant curl"
LIB_KEEP="libubox.so libubus.so libubus.so.1 libblobmsg_json.so libjson-c.so libjson-c.so.5 libjson-c.so.5.1.0 libuci.so libnl-3.so libnl-3.so.200 libnl-3.so.200.26.0 libnl-genl-3.so libnl-genl-3.so.200 libnl-genl-3.so.200.26.0 libnl-route-3.so libnl-route-3.so.200 libnl-route-3.so.200.26.0 libssl.so libssl.so.1.1 libcrypto.so libcrypto.so.1.1 libpng.so libpng16.so libpng16.so.16 libpng16.so.16.34.0 libz.so libz.so.1 libz.so.1.2.11"
cp -a "$STAGE/bin/." "$PAY/root/moore4c/bin/"
for f in $(cd "$PAY/root/moore4c/bin" && ls -la | grep -v "^l" | grep -vE "^total|^d" | awk '{print $NF}' | grep -vE "^($(echo $BIN_KEEP | tr ' ' '|'))$"); do
  rm -f "$PAY/root/moore4c/bin/$f"
done
cp -a "$STAGE/lib/." "$PAY/root/moore4c/lib/"
for f in $(cd "$PAY/root/moore4c/lib" && ls | grep -vE "^($(echo $LIB_KEEP | tr ' ' '|'))$"); do
  rm -f "$PAY/root/moore4c/lib/$f"
done
# 剥离 glibc 2.30 核心 — 设备系统是 glibc 2.31, 混用必段错误 (11-06 事故结论)
# libstdc++/libcrypto/mosquitto/mi_* 等 Aqara 专有库保留
( cd "$PAY/root/moore4c/lib" && rm -f \
    ld-2.30.so ld-linux-armhf.so.3 libc-2.30.so libc.so.6 \
    libdl-2.30.so libdl.so.2 libm-2.30.so libm.so.6 \
    libnss_dns-2.30.so libnss_dns.so.2 libnss_files-2.30.so libnss_files.so.2 \
    libpthread-2.30.so libpthread.so.0 libresolv-2.30.so libresolv.so.2 \
    librt-2.30.so librt.so.1 )

# 2b. 最新主程序 (工作区 konke 版) + relay.sh(app 继电器调用 $R/bin/relay.sh) + 字体资源
cp -f "$SCRIPTS/s1e_standalone_app_konke" "$PAY/root/moore4c/bin/"
cp -f "$SCRIPTS/relay.sh" "$PAY/root/moore4c/bin/"
cp -f "$SCRIPTS/opposans_ui_subset.ttf"   "$PAY/root/moore4c/res/OPPOSans-R.ttf"

# 2c. start.sh (v9 共存模式重建)
cat > "$PAY/root/moore4c/start.sh" <<'EOS'
#!/bin/sh
# moore4c launcher v12 — voice coexistence mode
# lua 保持运行(语音链: GX8002→UART→libccusdk→lua→ubus 必须它活着),
# app 在其后启动覆盖显示; 语音交互时原厂语音 UI 会短暂出现(正常反馈).
R=/data/moore4c
export LD_LIBRARY_PATH=$R/lib
export PATH=$R/bin:$PATH
# 本地中枢网关(米家 MIPS mTLS 直连, 云通道之外的本地双通道之一)
export NX5_MIPS_IP=192.168.50.227

# WiFi glue: nl80211 驱动 + 状态栏 SSID 回退源 + save_config 持久化。
# wpa 直接用 /data/wpa.conf(持久层): save_config 直写持久文件。
# 配置文件损坏导致 wpa 启动失败时自动修复: 抢救 network{ssid=..} 块
# 重建重试 → 仍失败重置骨架(WiFi 需重配, eth0/web 不受影响)。
WPA_CONF=/data/wpa.conf
[ -f "$WPA_CONF" ] || printf 'ctrl_interface=/var/run/wpa_supplicant\nap_scan=1\nupdate_config=1\n' > "$WPA_CONF"
wpa_try_start() {
  wpa_supplicant -B -Dnl80211 -iwlan0 -c "$WPA_CONF" >/tmp/m4c-wpa.log 2>&1
  sleep 2
  ps | grep wpa_supplicant | grep -v grep >/dev/null 2>&1
}
if ! ps | grep wpa_supplicant | grep -v grep >/dev/null 2>&1; then
  if ! wpa_try_start; then
    cp -f "$WPA_CONF" "$WPA_CONF.bad" 2>/dev/null
    printf 'ctrl_interface=/var/run/wpa_supplicant\nap_scan=1\nupdate_config=1\n' > "$WPA_CONF"
    awk '/network[[:space:]]*=[[:space:]]*\{/{b=1;s=""} b{s=s $0 "\n"; if($0~/ssid[[:space:]]*=/)k=1; if($0~/\}/){if(k)printf "%s",s; b=0;k=0}}' "$WPA_CONF.bad" >> "$WPA_CONF"
    echo "[wifi-glue] config repaired from $WPA_CONF.bad ($(date))" >>/tmp/m4c-boot.log
    if ! wpa_try_start; then
      printf 'ctrl_interface=/var/run/wpa_supplicant\nap_scan=1\nupdate_config=1\n' > "$WPA_CONF"
      echo "[wifi-glue] salvage failed, config reset to skeleton ($(date))" >>/tmp/m4c-boot.log
      wpa_try_start
    fi
  fi
  ( sleep 3; udhcpc -i wlan0 -b -q -t 20 >/dev/null 2>&1 ) &
fi
wpa_cli -i wlan0 set update_config 1 >/dev/null 2>&1

# 清理旧实例
for n in property_service ubusd miio_agent sysservice s1e_standalone_app_konke httpd; do
  p=$(ps | grep "$R/bin/$n" | grep -v grep | awk '{print $1}')
  [ -n "$p" ] && kill -9 $p 2>/dev/null
done

$R/bin/property_service   >/tmp/m4c-ps.log   2>&1 &
$R/bin/ubusd              >/tmp/m4c-ud.log   2>&1 &
sleep 1
LD_LIBRARY_PATH=$R/lib $R/bin/miio_agent  >/tmp/m4c-miio.log  2>&1 &
( for i in 1 2 3 4 5; do
    LD_LIBRARY_PATH=$R/lib $R/bin/sysservice -l d >>/tmp/m4c-ss.log 2>&1
    sleep 2
  done ) &
sleep 1
LD_LIBRARY_PATH=$R/lib $R/bin/s1e_standalone_app_konke >/tmp/m4c-s1e.log 2>&1 &
$R/bin/busybox httpd -p 8080 -h /data/www >/tmp/m4c-httpd.log 2>&1 &
echo "moore4c v11 started (display-first boot, web console on :8080)"
EOS

# 2d. scripts 白名单
( cd "$SCRIPTS" && tar -cf - \
    api.cgi index.html s1e_standalone_app_konke relay.sh do_ota.sh fetch_https.sh \
    http_body_strip layout_p0.json version.json release_version.json \
    ha_cards.json ha_config.json sys_settings.json switch_config.json \
    date_system_22.bin date_system_28.bin digits_110x120.bin digits_36.bin \
    digits_44x48.bin digits_oppo_58_native.bin emoji_index.bin emojis_compact.bin \
    font_opposans_12.bin font_opposans_15.bin hanzi_24.bin hanzi_30.bin hanzi_48.bin \
    opposans_ui_subset.ttf flame.png emojis.rgba voice_map.json ) \
  | ( cd "$PAY/scripts" && tar -xf - )
[ -f "$SCRIPTS/.gh_token" ] && cp -f "$SCRIPTS/.gh_token" "$PAY/scripts/"

# 2f-b. 自动激活: 授权码来源 = 环境变量 LICENSE_CODE > keys/auto.lic(单设备固定码)
#        设备端安装后经本地 CGI 调用激活(机器码不符则静默跳过, 无害)
LICENSE_CODE="${LICENSE_CODE:-}"
[ -z "$LICENSE_CODE" ] && [ -f "$WS/keys/auto.lic" ] && LICENSE_CODE=$(head -1 "$WS/keys/auto.lic" | tr -d '[:space:]')
[ -n "$LICENSE_CODE" ] && printf '{"code":"%s"}' "$LICENSE_CODE" > "$PAY/m4c_license.json"

# 2e. web 控制台(busybox httpd 仅认 /cgi-bin/ 路径); 米家凭据默认不带(WITH_CREDS=1 才装, 干净安装)
mkdir -p "$PAY/www/cgi-bin"
cp -f "$SCRIPTS/index.html" "$PAY/www/"
cp -f "$SCRIPTS/api.cgi" "$PAY/www/cgi-bin/"
if [ "${WITH_CREDS:-0}" = "1" ]; then
  cp -f "$MIJIA_JSON" "$PAY/cred/mijia.json"
  cp -f "$CRED/mijia_ca.cert" "$CRED/mips_26705031.key" "$CRED/mips_26705031.cert" "$PAY/cred/"
  cp -f "$CRED/mijia_devnm.json" "$CRED/mijia_climx.json" "$CRED/mips_0.key" "$PAY/cred/" 2>/dev/null || true
fi

# 2f. 开机自启项 — display-first hybrid 接管(原厂 UI 零闪现):
# fyfb 显示初始化唯一触发点 = lua 框架首次 open fb0(其前置 MPP init
# /dev/sys,/dev/vb,/dev/vppu,/dev/vo 无法从 app 侧复刻——vppu open 回调
# 依赖它)。故保留 stock S90app 启动 lua, S91 以 200ms 轮询在 lua open
# fb0 的瞬间 STOP(一帧未渲染), 自研 app 立即接管 + 15s 守护自愈。
#!/bin/sh
# display-first hybrid: 等 stock lua 完成 fb0 初始化(首次 open 同步触发
# vo_enable+lcm init 全套)的瞬间 STOP 它——原厂 UI 零闪现;然后自研栈接管。
(
  while true; do
    lp=$(ps | grep "lua_framework/main.lua" | grep -v grep | awk '{print $1}')
    [ -n "$lp" ] || { sleep 0.2; continue; }
    if ls -la /proc/$lp/fd 2>/dev/null | grep -q fb0; then
      kill -STOP $lp 2>/dev/null
      echo "lua took over at $(date) after fb0-open" >>/tmp/m4c-boot.log
      break
    fi
    sleep 0.2
  done
  sh /data/moore4c/start.sh >/tmp/m4c-boot.log 2>&1
  while true; do
    sleep 15
    ps | grep s1e_standalone_app_konke | grep -v grep >/dev/null || \
      sh /data/moore4c/start.sh >>/tmp/m4c-boot.log 2>&1
    # wpa 看门狗: rtl8723ds 驱动崩溃会带走 wpa_supplicant(socket 消失,
    # wpa_cli 报 No such file or directory), 这里拉回 + 续 DHCP
    ps | grep wpa_supplicant | grep -v grep >/dev/null || \
      sh /data/moore4c/start.sh >>/tmp/m4c-boot.log 2>&1
  done
) &# 2g. 清 AppleDouble 垃圾后打 tar 包 (root 属主, 无 xattr)
find "$PAY" -name "._*" -o -name ".DS_Store" | xargs rm -f 2>/dev/null
export COPYFILE_DISABLE=1
( cd "$PAY/root"    && tar --uid 0 --gid 0 -czf "$PAY/m4c_root.tgz" moore4c )
( cd "$PAY/scripts" && tar --uid 0 --gid 0 -czf "$PAY/m4c_scripts.tgz" . )
( cd "$PAY/www"     && tar --uid 0 --gid 0 -czf "$PAY/m4c_www.tgz" . )
[ -n "$(ls -A "$PAY/cred" 2>/dev/null)" ] && ( cd "$PAY/cred" && tar --uid 0 --gid 0 -czf "$PAY/m4c_cred.tgz" . )
( cd "$PAY/init.d"  && tar --uid 0 --gid 0 -czf "$PAY/m4c_init.tgz" . )
( cd "$WS/usr/share" && tar --uid 0 --gid 0 --no-xattrs -czf "$PAY/m4c_theme.tgz" aqgui )
cp -f "$WS/installer/S90app_fastboot" "$PAY/m4c_s90app_fast"
cp -f "$WS/tools/fb0stop.so" "$PAY/m4c_fb0stop.so"

# ---------- 3. 远程安装脚本 ----------
cat > "$PAY/install_remote.sh" <<'EOS'
#!/bin/sh
# 检查 /tmp 空间 (需 >30MB)
free_kb=$(df -k /data 2>/dev/null | tail -1 | awk '{print $4}')
[ -n "$free_kb" ] && [ "$free_kb" -lt 61440 ] && { echo "DATA-SPACE-LOW: ${free_kb}KB free"; exit 1; }

# md5 校验
for f in m4c_root m4c_scripts m4c_www m4c_cred m4c_init m4c_theme; do
  [ -f /data/m4c_pkg_$f.tgz ] || continue
  want=$(grep "^$f " /data/m4c_md5.txt | awk '{print $2}')
  got=$(md5sum /data/m4c_pkg_$f.tgz | awk '{print $1}')
  [ "$want" = "$got" ] || { echo "MD5-MISMATCH: $f want=$want got=$got"; exit 1; }
done
echo "md5 ok"

# 部署 (覆盖式: 包内同名文件覆盖, 其他文件一律保留; 只有卸载才清空)
mkdir -p /data/scripts /data/www /etc/config/intercom /data/moore4c
( cd /data                && gzip -dc /data/m4c_pkg_m4c_root.tgz    | tar -x )
( cd /data/scripts        && gzip -dc /data/m4c_pkg_m4c_scripts.tgz | tar -x )
( cd /data/www            && gzip -dc /data/m4c_pkg_m4c_www.tgz     | tar -x )
[ -f /data/m4c_pkg_m4c_cred.tgz ] && ( cd /etc/config/intercom && gzip -dc /data/m4c_pkg_m4c_cred.tgz | tar -x )
( cd /etc/init.d          && gzip -dc /data/m4c_pkg_m4c_init.tgz    | tar -x )
mkdir -p /usr/share
# S90app fast-boot 版覆盖(原厂版备份到 /data/S90app.stock; lua 极速直启, 重资产后台化)
if [ ! -f /data/S90app.stock ] && [ -f /etc/init.d/S90app ]; then
  cp -f /etc/init.d/S90app /data/S90app.stock
fi
cp -f /data/m4c_s90app_fast /etc/init.d/S90app
chmod +x /etc/init.d/S90app
rm -rf /usr/share/aqgui
( cd /usr/share           && gzip -dc /data/m4c_pkg_m4c_theme.tgz   | tar -x )
chmod +x /etc/init.d/S91moore4c /data/moore4c/start.sh
chmod 755 /data/moore4c/bin/* 2>/dev/null
chmod +x /data/scripts/relay.sh /data/scripts/do_ota.sh /data/scripts/fetch_https.sh \
         /data/scripts/http_body_strip /data/scripts/api.cgi /data/www/api.cgi
[ -f /data/scripts/.gh_token ] && chmod 600 /data/scripts/.gh_token
chmod 600 /etc/config/intercom/* 2>/dev/null
echo "deployed"

# 自动激活(本地 CGI 直调, 不依赖 httpd; 机器码不符=静默跳过)
if [ -f /data/m4c_license.json ]; then
  code=$(sed -n 's/.*"code":"\([^"]*\)".*/\1/p' /data/m4c_license.json)
  if [ -n "$code" ]; then
    body="{\"code\":\"$code\"}"
    echo "$body" | QUERY_STRING="action=license_activate" REQUEST_METHOD=POST \
      CONTENT_LENGTH=$(printf %s "$body" | wc -c) /data/www/cgi-bin/api.cgi >/tmp/m4c_act.log 2>&1
    grep -q '"ok":true' /tmp/m4c_act.log && echo "license: activated" || echo "license: not activated (code mismatch?)"
  fi
  rm -f /data/m4c_license.json
fi

# 立即启动
sh /data/moore4c/start.sh >/tmp/m4c-boot.log 2>&1
sleep 3
echo "=== process check ==="
ps | grep moore4c/bin | grep -v grep
rm -f /data/m4c_pkg_*.tgz /data/install_remote.sh /data/m4c_md5.txt
echo "=== install done ==="
EOS

# md5 清单 (含 install_remote.sh 自身)
: > "$PAY/m4c_md5.txt"
for f in m4c_root m4c_scripts m4c_www m4c_cred m4c_init m4c_theme; do
  [ -f "$PAY/$f.tgz" ] && echo "$f $(md5 -q "$PAY/$f.tgz")" >> "$PAY/m4c_md5.txt"
done

# ---------- 4. 预检设备 /tmp 空间 ----------
say "预检设备 /data 空间..."
TMPKB=$("$INS/sshrun.exp" "df -k /data | tail -1 | awk '{print \$4}'" 2>/dev/null | grep -v password | tail -1 | tr -dc '0-9')
[ -n "$TMPKB" ] && [ "$TMPKB" -lt 102400 ] && fail "设备 /data 空间不足 (${TMPKB}KB < 100MB)"

# ---------- 5. 上传 ----------
say "上传 payload 到 $IP ..."
for f in m4c_root.tgz m4c_scripts.tgz m4c_www.tgz m4c_cred.tgz m4c_init.tgz m4c_theme.tgz; do
  [ -f "$PAY/$f" ] || continue
  "$INS/scp.exp" "$PAY/$f" "/data/m4c_pkg_$f" >/dev/null 2>&1 || fail "上传失败: $f"
  echo "  uploaded: $f"
done
"$INS/scp.exp" "$PAY/install_remote.sh" "/data/install_remote.sh" >/dev/null 2>&1 && echo "  uploaded: install_remote.sh" || fail "上传失败: install_remote.sh"
"$INS/scp.exp" "$PAY/m4c_md5.txt" "/data/m4c_md5.txt" >/dev/null 2>&1 && echo "  uploaded: m4c_md5.txt" || fail "上传失败: m4c_md5.txt"
[ -f "$PAY/m4c_license.json" ] && "$INS/scp.exp" "$PAY/m4c_license.json" "/data/m4c_license.json" >/dev/null 2>&1 && echo "  uploaded: m4c_license.json (auto-activate)" 

# ---------- 6. 远程执行安装 ----------
say "远程安装..."
OUT=$("$INS/sshrun.exp" "sh /data/install_remote.sh" 2>&1 | grep -vE "password:|spawn")
echo "$OUT"

# ---------- 7. 汇报 ----------
if echo "$OUT" | grep -q "=== install done ==="; then
  say "===== 安装成功 ====="
else
  say "===== 安装异常，请检查上方输出 ====="
  exit 1
fi
echo "  仪表盘: 屏幕直接显示 (开机场景为 20s 后)"
echo "  Web 控制台: http://$IP:8080"
echo "  设备端日志: /tmp/m4c-boot.log /tmp/m4c-s1e.log /tmp/m4c-miio.log"
echo "  排障: ssh root@$IP 'cat /tmp/m4c-s1e.log'"
