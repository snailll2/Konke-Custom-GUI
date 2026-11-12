#!/bin/bash
# ============================================================================
# install.sh — Moore 4c(Konke 面板) 一键安装/升级 — 发布仓版(无本地依赖)
# 用法:   ./install.sh <设备IP>
# 例:     ./install.sh 192.168.50.120
# 依赖:   bash + expect + curl(macOS/Linux 常见自带); 设备与电脑同网段
# 固件包: 优先用本仓库 release/s1e_custom_gui_latest.tar.gz,
#         没有则自动从 GitHub 拉最新版。
# 行为:   覆盖式部署(用户配置/授权/语音映射全保留), 已装设备直接升级;
#         全新原厂设备请先按 README 获取完整固件后再运行。
# ============================================================================
set -u

IP="${1:-}"
[ -z "$IP" ] && { echo "用法: $0 <设备IP>   例: $0 192.168.50.120"; exit 1; }

PW="p9z34c"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/moore4c-install.XXXXXX)"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=$WORK/known_hosts -o ConnectTimeout=10"
PKG="$WORK/s1e_custom_gui_latest.tar.gz"

fail() { echo "[安装失败] $*"; rm -rf "$WORK"; exit 1; }
say()  { echo "[moore4c-install] $*"; }

# ---------- expect 助手(独立临时目录, 不写死任何本地路径) ----------
cat > "$WORK/scp.exp" <<EOF
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
cat > "$WORK/sshrun.exp" <<EOF
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
chmod +x "$WORK/scp.exp" "$WORK/sshrun.exp"

# ---------- 1. ping 预检 ----------
say "ping $IP ..."
ping -c 2 -t 3 "$IP" >/dev/null 2>&1 || fail "设备不可达: $IP"

# ---------- 2. 固件包: 仓库内优先, 否则 GitHub ----------
if [ -f "$HERE/../release/s1e_custom_gui_latest.tar.gz" ]; then
  cp -f "$HERE/../release/s1e_custom_gui_latest.tar.gz" "$PKG"
  say "使用仓库内固件包 ($(du -k "$PKG" | cut -f1)KB)"
else
  say "从 GitHub 下载最新固件包..."
  curl -skfL -m 300 -o "$PKG" \
    "https://raw.githubusercontent.com/snailll2/Konke-Custom-GUI/main/release/s1e_custom_gui_latest.tar.gz" \
    || fail "固件包下载失败(检查网络)"
  say "已下载 ($(du -k "$PKG" | cut -f1)KB)"
fi
tar -tzf "$PKG" >/dev/null 2>&1 || fail "固件包损坏"

# ---------- 3. 设备端部署脚本 (与 OTA 安装逻辑一致) ----------
cat > "$WORK/install_remote.sh" <<'REOF'
#!/bin/sh
FREE_KB=$(df -k /data 2>/dev/null | tail -1 | awk '{print $4}')
[ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 40960 ] && { echo "DATA-SPACE-LOW: ${FREE_KB}KB"; exit 1; }
[ -f /data/moore4c/start.sh ] || { echo "NOT-INSTALLED: 设备上无 /data/moore4c/start.sh, 全新原厂设备请先完整刷入固件(见 README)"; exit 1; }
OTA_DIR=/data/moore4c/ota
mkdir -p $OTA_DIR/staging
tar -xzf /data/moore4c/ota/pkg.tar.gz -C $OTA_DIR/staging/ || { echo "EXTRACT-FAIL"; exit 1; }
for CFG in layout_p0.json sys_settings.json ha_config.json ha_cards.json lock_text.json notify_history.json energy_stats.json voice_map.json tile_entities.json license.json passwd .gesture_guide_seen; do
    [ -f "/data/scripts/$CFG" ] && rm -f "$OTA_DIR/staging/$CFG"
done
cp -f $OTA_DIR/staging/* /data/scripts/ 2>/dev/null
cp -f /data/scripts/s1e_standalone_app_konke /data/moore4c/bin/ 2>/dev/null
cp -f /data/scripts/relay.sh /data/moore4c/bin/ 2>/dev/null
mkdir -p /data/www/cgi-bin
cp -f /data/scripts/index.html /data/www/index.html 2>/dev/null
cp -f /data/scripts/api.cgi /data/www/cgi-bin/api.cgi 2>/dev/null
rm -rf $OTA_DIR
chmod 755 /data/moore4c/bin/* /data/scripts/api.cgi /data/scripts/relay.sh /data/scripts/do_ota.sh /data/scripts/fetch_https.sh /data/scripts/http_body_strip /data/scripts/index.html 2>/dev/null
chmod 644 /data/scripts/*.json /data/scripts/*.bin /data/www/index.html 2>/dev/null
sh /data/moore4c/start.sh >/tmp/m4c-boot.log 2>&1
sleep 8
echo "=== process check ==="
ps | grep moore4c/bin | grep -v grep
OK=0
for n in s1e_standalone_app_konke property_service ubusd miio_agent; do
  ps | grep -q "$n" && OK=$((OK+1))
done
echo "=== alive $OK/4 ==="
[ "$OK" -ge 3 ] && echo "=== install done ===" || { echo "=== install failed, check /tmp/m4c-boot.log ==="; exit 1; }
REOF

# ---------- 4. 上传 ----------
say "上传固件包到 $IP ..."
"$WORK/sshrun.exp" "mkdir -p /data/moore4c/ota" >/dev/null 2>&1
"$WORK/scp.exp" "$PKG" "/data/moore4c/ota/pkg.tar.gz" >/dev/null 2>&1 || fail "上传失败: 固件包"
"$WORK/scp.exp" "$WORK/install_remote.sh" "/tmp/install_remote_$$.sh" >/dev/null 2>&1 || fail "上传失败: 部署脚本"

# ---------- 5. 远程执行 ----------
say "远程部署..."
OUT=$("$WORK/sshrun.exp" "sh /tmp/install_remote_$$.sh; rm -f /tmp/install_remote_$$.sh" 2>&1 | grep -vE "password:|spawn")
echo "$OUT"
rm -rf "$WORK"

echo "$OUT" | grep -q "=== install done ===" && say "===== 安装成功 =====" || { say "===== 安装异常，请检查上方输出 ====="; exit 1; }
say "  仪表盘: 屏幕直接显示"
say "  Web 控制台: http://$IP:8080"
say "  排障: ssh root@$IP 'cat /tmp/m4c-boot.log /tmp/m4c-s1e.log'"
