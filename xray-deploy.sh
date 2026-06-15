#!/bin/bash
#=============================================================================
#  Xray Reality + WS 一键部署脚本
#  =====================================
#  目标: 在新 Debian/Ubuntu VPS 上以 root 运行，从零到可用的一站式部署
#  效果: VLESS+Reality :8443 + VLESS+WS :2087 + SOCKS5 :1080 (local)
#
#  用法: curl -sL https://raw.githubusercontent.com/... | bash
#    或: scp xray-deploy.sh root@<IP>:/root/ && ssh root@<IP> bash /root/xray-deploy.sh
#
#  兼容: Debian 10/11/12, Ubuntu 20.04/22.04/24.04
#=============================================================================

# ── 设置项 ──────────────────────────────────────────────────────────────────
REALITY_PORT=8443
WS_PORT=2087
SNI="www.microsoft.com"
WS_PATH="/ws"
MEMORY_MAX="100M"
MEMORY_HIGH="80M"
LIMIT_NOFILE=65535

# ── Color ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'

log()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
banner() { echo -e "\n${BOLD}$1${NC}"; echo "───────────────────────────────────────────────"; }

# ── 检查 root ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "必须以 root 运行"
  exit 1
fi

# ── 检查 OS ──────────────────────────────────────────────────────────────────
OS=""
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS="$ID"
fi
case "$OS" in
  debian|ubuntu) ;;
  *) warn "未知系统: $OS (仅测试过 Debian/Ubuntu)" ;;
esac

XRAY_BIN="/usr/local/bin/xray"
CONFIG_FILE="/etc/xray-config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
LOG_DIR="/var/log"
ACCESS_LOG="$LOG_DIR/xray-access.log"
ERROR_LOG="$LOG_DIR/xray-error.log"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Xray Reality + WS 一键部署                     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ════════════════════════════════════════════════════════════════════════════
#  1. 系统初始化
# ════════════════════════════════════════════════════════════════════════════
banner "Step 1: 系统初始化"

# Swap (如果 < 512MB 才加)
swap_total=$(free -m | awk '/^Swap:/ {print $2}')
if [[ $swap_total -lt 256 ]]; then
  info "添加 512MB swap..."
  fallocate -l 512M /swapfile && chmod 600 /swapfile
  mkswap /swapfile && swapon /swapfile
  if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  info "swap 已添加"
else
  info "swap 已够用 (${swap_total}MB)"
fi

# Timezone
if [[ "$(cat /etc/timezone 2>/dev/null)" != "Asia/Shanghai" ]]; then
  timedatectl set-timezone Asia/Shanghai 2>/dev/null || ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  log "时区设置为 Asia/Shanghai"
else
  info "时区已是 Asia/Shanghai"
fi

# BBR
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]]; then
  info "启用 BBR..."
  cat >> /etc/sysctl.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -p 2>/dev/null
  log "BBR 已启用"
else
  info "BBR 已启用"
fi

# ════════════════════════════════════════════════════════════════════════════
#  2. 安装 Xray
# ════════════════════════════════════════════════════════════════════════════
banner "Step 2: 安装 Xray"

if [[ -x "$XRAY_BIN" ]]; then
  info "Xray 已安装: $($XRAY_BIN version 2>/dev/null | head -1)"
  XRAY_INSTALLED=true
else
  XRAY_INSTALLED=false
  info "下载 Xray 最新版本..."
  bash <(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install \
    && log "Xray 安装成功" \
    || { err "Xray 安装失败"; exit 1; }
fi

# ════════════════════════════════════════════════════════════════════════════
#  3. 生成密钥
# ════════════════════════════════════════════════════════════════════════════
banner "Step 3: 生成密钥"

UUID=$($XRAY_BIN uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
KEYPAIR=$($XRAY_BIN x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep 'Private key:' | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep 'Public key:' | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

if [[ -z "$PRIVATE_KEY" ]]; then
  err "密钥生成失败"
  exit 1
fi

log "UUID:      $UUID"
log "PublicKey: $PUBLIC_KEY"
log "ShortId:   $SHORT_ID"

# ════════════════════════════════════════════════════════════════════════════
#  4. 写入配置
# ════════════════════════════════════════════════════════════════════════════
banner "Step 4: 写入 Xray 配置"

cat > "$CONFIG_FILE" << CONF
{
  "log": {
    "loglevel": "warning",
    "access": "${ACCESS_LOG}",
    "error": "${ERROR_LOG}"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "port": ${REALITY_PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "fakedns"]
      },
      "mux": {
        "enabled": true,
        "concurrency": 8
      },
      "tcpFastOpen": true
    },
    {
      "tag": "vless-ws",
      "port": ${WS_PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID}"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "${WS_PATH}"}
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "tag": "socks-in",
      "port": 1080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": []
  }
}
CONF

log "配置已写入 ${CONFIG_FILE}"

# 验证配置
info "验证配置..."
$XRAY_BIN run -c "$CONFIG_FILE" -test 2>&1 | grep -v 'Warning\|Info\|REALITY\|deprecated'
if [[ $? -eq 0 || $? -eq 141 ]]; then
  log "配置验证通过"
else
  # grep 141 = 管道中断（不确定结果），再看 exit
  $XRAY_BIN run -c "$CONFIG_FILE" -test >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    err "配置验证失败"
    exit 1
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
#  5. systemd service
# ════════════════════════════════════════════════════════════════════════════
banner "Step 5: 配置 systemd 服务"

# 如果是通过官方脚本安装的，可能已有 service，覆盖增强
cat > "$SERVICE_FILE" << SERV
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=${LIMIT_NOFILE}
MemoryMax=${MEMORY_MAX}
MemoryHigh=${MEMORY_HIGH}
OOMScoreAdjust=-100

[Install]
WantedBy=multi-user.target
SERV

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
  log "Xray 服务运行中"
else
  err "Xray 服务启动失败"
  systemctl status xray --no-pager | tail -10
  exit 1
fi

# ════════════════════════════════════════════════════════════════════════════
#  6. 防火墙
# ════════════════════════════════════════════════════════════════════════════
banner "Step 6: 配置 iptables 防火墙"

# IPv4
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -F INPUT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport ${REALITY_PORT} -j ACCEPT
iptables -A INPUT -p tcp --dport ${WS_PORT} -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# IPv6
ip6tables -P INPUT DROP 2>/dev/null
ip6tables -P FORWARD DROP 2>/dev/null
ip6tables -F INPUT 2>/dev/null
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null
ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null

# 持久化
if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save 2>/dev/null
elif command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
  warn "iptables-persistent 未安装，已手动保存规则到 /etc/iptables/"
  info "建议: apt install iptables-persistent -y"
fi

log "防火墙规则已生效"
iptables -L INPUT -n --line-numbers 2>/dev/null | head -8

# ════════════════════════════════════════════════════════════════════════════
#  7. fail2ban
# ════════════════════════════════════════════════════════════════════════════
banner "Step 7: fail2ban"

if command -v fail2ban-client &>/dev/null; then
  info "fail2ban 已安装"
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban 2>/dev/null
  log "fail2ban 已安装"
fi

# 确保 sshd jail 启用
mkdir -p /etc/fail2ban
cat > /etc/fail2ban/jail.local << 'JAIL'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
JAIL

systemctl enable --now fail2ban 2>/dev/null
systemctl restart fail2ban 2>/dev/null
log "fail2ban 已启用"

# ════════════════════════════════════════════════════════════════════════════
#  8. SSH 安全加固
# ════════════════════════════════════════════════════════════════════════════
banner "Step 8: SSH 安全加固"

sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || true
if ! grep -q '^PermitRootLogin prohibit-password' /etc/ssh/sshd_config; then
  echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
fi
systemctl restart sshd
log "SSH 安全加固完成（密码登录禁用，root 仅证书登录）"

# SSH Banner
cat > /etc/ssh/banner << 'BAN'
╔══════════════════════════════════════════════════════════╗
║              Xray Proxy Service — Deployed              ║
╠══════════════════════════════════════════════════════════╣
║  VLESS+Reality  :8443  (TCP, xtls-rprx-vision)         ║
║  VLESS+WS       :2087  (/ws)                            ║
║  SOCKS5         :1080  (local only)                     ║
╠══════════════════════════════════════════════════════════╣
║  Xray  |  BBR  |  fail2ban  |  ulimit 65535            ║
╚══════════════════════════════════════════════════════════╝
BAN

sed -i '/^Banner /d' /etc/ssh/sshd_config
sed -i '/^PermitRootLogin/i\Banner /etc/ssh/banner' /etc/ssh/sshd_config
systemctl restart sshd
log "SSH Banner 已配置"

# ════════════════════════════════════════════════════════════════════════════
#  9. logrotate
# ════════════════════════════════════════════════════════════════════════════
banner "Step 9: 配置 logrotate"

cat > /etc/logrotate.d/xray << LOGROT
${ACCESS_LOG} ${ERROR_LOG} {
    daily
    rotate 7
    maxsize 10M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGROT
log "logrotate 已配置"

# ════════════════════════════════════════════════════════════════════════════
#  10. 最终验证
# ════════════════════════════════════════════════════════════════════════════
banner "Step 10: 验证"

echo ""
ss -tlnp 2>/dev/null | grep xray || ss -tlnp 2>/dev/null | grep ${REALITY_PORT}
echo ""

echo "  Xray systemd 状态: $(systemctl is-active xray)"
echo "  SOCKS5 代理测试:"
curl -x socks5h://127.0.0.1:1080 -s --max-time 10 https://www.baidu.com -o /dev/null -w "  → baidu.com  HTTP %{http_code} (%{time_total}s)\n" 2>/dev/null
curl -x socks5h://127.0.0.1:1080 -s --max-time 10 https://www.google.com -o /dev/null -w "  → google.com HTTP %{http_code} (%{time_total}s)\n" 2>/dev/null

# ════════════════════════════════════════════════════════════════════════════
#  Share Links
# ════════════════════════════════════════════════════════════════════════════
banner "Share Links （导入 v2rayN）"

HOST=$(curl -s http://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')

REALITY_LINK="vless://${UUID}@${HOST}:${REALITY_PORT}?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&fp=chrome&sni=${SNI}#Xray-Reality"
WS_LINK="vless://${UUID}@${HOST}:${WS_PORT}?type=ws&path=%2Fws&security=none#Xray-WS"

echo ""
echo -e "  ${CYAN}Reality (主力):${NC}"
echo "  ${REALITY_LINK}"
echo ""
echo -e "  ${CYAN}WebSocket (备用):${NC}"
echo "  ${WS_LINK}"
echo ""

# ════════════════════════════════════════════════════════════════════════════
#  运维文档
# ════════════════════════════════════════════════════════════════════════════
banner "运维速查"

echo ""
cat << CHEAT
  服务状态: systemctl status xray
  重启服务: systemctl restart xray
  实时日志: tail -f ${ACCESS_LOG}
  错误日志: tail -f ${ERROR_LOG}
  监听端口: ss -tlnp | grep xray
  防火墙:   iptables -L INPUT -n
  fail2ban: fail2ban-client status sshd

  Config:  ${CONFIG_FILE}
  Service: ${SERVICE_FILE}
  Binary:  ${XRAY_BIN}
CHEAT

# ── 写入运维文档 ──────────────────────────────────────────────────────────────
cat > /root/README-deploy.log << EOF
╔══════════════════════════════════════════════════════════╗
║  Xray Proxy Deployment — \$(date '+%Y-%m-%d %H:%M CST')              ║
╚══════════════════════════════════════════════════════════╝

Server: $HOST
OS:     $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')

=== Share Links ===

Reality: ${REALITY_LINK}
WS:      ${WS_LINK}

=== Keys ===

UUID:       $UUID
PublicKey:  $PUBLIC_KEY
PrivateKey: $PRIVATE_KEY
ShortId:    $SHORT_ID
SNI:        $SNI

=== Files ===

/usr/local/bin/xray
/etc/xray-config.json
/etc/systemd/system/xray.service
/etc/logrotate.d/xray
/etc/iptables/rules.v4
/etc/iptables/rules.v6
/var/log/xray-access.log
/var/log/xray-error.log

=== Commands ===

systemctl restart xray
systemctl status xray
journalctl -u xray --follow
tail -f ${ACCESS_LOG}
iptables -L INPUT -n
fail2ban-client status sshd
ss -tlnp | grep xray

Last updated: $(date '+%Y-%m-%d %H:%M CST')
EOF

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  部署完成！复制上方 Share Link 到 v2rayN 即可使用         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
