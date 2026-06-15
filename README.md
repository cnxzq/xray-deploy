# Xray 一键部署脚本

VLESS+Reality + VLESS+WebSocket 代理服务一键部署。跑在新服务器上，从零到可用。

## 快速开始

在新 VPS 上以 **root** 运行：

```bash
curl -sL https://raw.githubusercontent.com/cnxzq/xray-deploy/main/xray-deploy.sh | bash
```

或者下载后执行：

```bash
wget https://raw.githubusercontent.com/cnxzq/xray-deploy/main/xray-deploy.sh
chmod +x xray-deploy.sh && ./xray-deploy.sh
```

## 部署内容

| 组件 | 说明 |
|------|------|
| VLESS+Reality | TCP 8443，xtls-rprx-vision，主力代理 |
| VLESS+WebSocket | TCP 2087，路径 /ws，备用通道 |
| SOCKS5 | localhost:1080，服务器端本地调试 |
| BBR | TCP 拥塞控制优化 |
| mux | 多路复用，concurrency=8 |
| TCP Fast Open | 首次连接加速 |
| iptables | 仅放行 SSH(22) + 代理端口(8443,2087) |
| IPv6 防火墙 | 默认 DROP，仅放行 SSH(22) |
| fail2ban | SSH 暴力破解防护 |
| logrotate | 日志轮转，保留7天 |
| SSH 加固 | 禁用密码登录，root 仅证书认证 |

## 系统要求

- Debian 10/11/12 或 Ubuntu 20.04/22.04/24.04
- 至少 256MB 内存（自动添加 swap）
- 以 root 运行

## 输出

部署完成后会打印：

1. **Reality 分享链接** — 主用，TCP 连接
2. **WebSocket 分享链接** — 备用，Reality 被封时切换

复制到 v2rayN / Nekobox / Clash Meta 等客户端即可使用。

## 运维命令

```bash
systemctl status xray      # 服务状态
systemctl restart xray     # 重启代理
tail -f /var/log/xray-access.log   # 实时访问日志
iptables -L INPUT -n       # 查看防火墙
fail2ban-client status sshd        # 查看防暴力破解
```

## 配置

部署时自动生成随机 UUID 和 Reality 密钥对。如需自定义，在脚本顶部修改：

```bash
REALITY_PORT=8443     # Reality 端口
WS_PORT=2087          # WebSocket 端口
SNI="www.microsoft.com"  # TLS 伪装域名
WS_PATH="/ws"         # WebSocket 路径
```

## 原理

```
客户端 (v2rayN)
    │
    ├── TCP :8443 ────→ VLESS+Reality ────→ 直连出口 (freedom)
    │                     (主力，抗封锁)
    │
    └── TCP :2087 ────→ VLESS+WebSocket ──→ 直连出口 (freedom)
                          (备用通道)
```

- Reality 协议伪装成 TLS 流量流向 `www.microsoft.com`，中间人难以识别
- mux 多路复用减少连接建立次数，提升网页浏览体验
- TCP Fast Open 减少首次连接的往返时间

## License

[MIT](LICENSE)
