# Clash for Docker介绍
![GitHub Repo stars](https://img.shields.io/github/stars/gangz1o/clash4docker?style=for-the-badge)
![GitHub forks](https://img.shields.io/github/forks/gangz1o/clash4docker?style=for-the-badge)
![GitHub contributors](https://img.shields.io/github/contributors/gangz1o/clash4docker?style=for-the-badge)
![GitHub repo size](https://img.shields.io/github/repo-size/gangz1o/clash4docker?style=for-the-badge)
![GitHub issues](https://img.shields.io/github/issues/gangz1o/clash4docker?style=for-the-badge)
![Docker Pulls](https://img.shields.io/docker/pulls/gangz1o/glash?style=for-the-badge)

🚀 基于最新 **Mihomo** 内核，内置 Dashboard 的 Clash Docker 镜像

## 核心特性

- ✅ Mihomo (Clash Meta)最新内核
- ✅ MetacubexD Web Dashboard 内置
- ✅ 预打包 GeoIP 数据库，无需运行时下载
- ✅ 支持 amd64 / arm64 架构
- ✅ **订阅功能**：支持远程订阅链接自动下载配置
- ✅ **自动更新**：支持定时自动更新订阅并重启生效
- ✅ **容错处理**：订阅下载失败时自动回退到本地配置

## 支持的协议

| 协议             | 说明                      |
| ---------------- | ------------------------- |
| Shadowsocks (SS) | 经典轻量级加密代理        |
| VMess            | V2Ray 原生协议            |
| VLESS            | V2Ray 轻量协议，性能更优  |
| Trojan           | 基于 TLS 的隐蔽协议       |
| Hysteria         | 基于 QUIC 的高速协议      |
| Hysteria2        | Hysteria 第二代，更快更稳 |
| TUIC             | 基于 QUIC 的多路复用协议  |
| WireGuard        | 现代化 VPN 协议           |
| HTTP             | HTTP/HTTPS 代理           |
| SOCKS5           | 通用 SOCKS5 代理          |

## 快速开始

 Clash for Docker 支持两种使用模式：**订阅模式**（推荐）和**本地配置模式**。

### 模式一：订阅模式（推荐）

自动从订阅链接下载配置，支持定时更新，无需手动维护配置文件。

#### Docker Run

```bash
docker run -d \
  --name glash \
  --restart unless-stopped \
  -p 7890:7890 \
  -p 7891:7891 \
  -p 9090:9090 \
  -v /path/to/config:/root/.config/mihomo \
  -e SUB_URL=https://your-subscription-url.com/config \
  -e SUB_CRON="0 */6 * * *" \
  -e SECRET=your-dashboard-password \
  -e ALLOW_LAN=true \
  gangz1o/glash:latest
```

#### Docker Compose

```yaml
services:
  glash:
    image: gangz1o/glash:latest
    container_name: glash
    restart: always
    ports:
      - '7890:7890' # HTTP 代理
      - '7891:7891' # SOCKS5 代理
      - '9090:9090' # Dashboard
    volumes:
      - ./config:/root/.config/mihomo
    environment:
      - TZ=Asia/Shanghai
      - SUB_URL=https://your-subscription-url.com/config
      - SUB_CRON=0 */6 * * *
      - SECRET=your-dashboard-password
      - ALLOW_LAN=true
```

### 模式二：本地配置模式

使用本地 `config.yaml` 配置文件，适合手动管理配置的用户。

#### Docker Run

```bash
docker run -d \
  --name glash \
  --restart always \
  -p 7890:7890 \
  -p 7891:7891 \
  -p 9090:9090 \
  -v /path/to/config.yaml:/root/.config/mihomo/config.yaml:ro \
  gangz1o/glash:latest
```

#### Docker Compose

```yaml
services:
  glash:
    image: gangz1o/glash:latest
    container_name: glash
    restart: always
    ports:
      - '7890:7890' # HTTP 代理
      - '7891:7891' # SOCKS5 代理
      - '9090:9090' # Dashboard
    volumes:
      - ./config.yaml:/root/.config/mihomo/config.yaml:ro
    environment:
      - TZ=Asia/Shanghai
      - ALLOW_LAN=true
```

### 模式三：TUN 模式

TUN 模式可接管系统全局流量，无需手动配置代理。设置 `TUN_ENABLED=true` 后，每次重启均自动恢复 TUN 状态，无需手动在 Dashboard 中开启。

> ⚠️ **注意**：TUN 模式需要容器具有 `NET_ADMIN` 能力和 `/dev/net/tun` 设备，请勿在不受信任的环境中使用。

#### Docker Run

```bash
docker run -d \
  --name glash \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -p 7890:7890 \
  -p 7891:7891 \
  -p 9090:9090 \
  -v /path/to/config:/root/.config/mihomo \
  -e SUB_URL=https://your-subscription-url.com/config \
  -e TUN_ENABLED=true \
  gangz1o/glash:latest
```

#### Docker Compose

```yaml
services:
  glash:
    image: gangz1o/glash:latest
    container_name: glash
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - '7890:7890'
      - '7891:7891'
      - '9090:9090'
    volumes:
      - ./config:/root/.config/mihomo
    environment:
      - TZ=Asia/Shanghai
      - SUB_URL=https://your-subscription-url.com/config
      - TUN_ENABLED=true
```

### 指定架构下载

默认自动匹配当前平台，如需指定架构：

```bash
# x86_64 / amd64
docker pull --platform linux/amd64 gangz1o/glash:latest

# ARM64 (Apple Silicon / ARM 服务器)
docker pull --platform linux/arm64 gangz1o/glash:latest
```

## 订阅功能详解

> ⚠️ **重要提示**：使用订阅功能时，配置目录必须**可写**，不能使用 `:ro`（只读）模式挂载！

### 环境变量

| 变量               | 说明                                                           | 示例                      |
| ------------------ | -------------------------------------------------------------- | ------------------------- |
| `SUB_URL`          | 订阅地址，支持返回 Clash 配置的链接                            | `https://example.com/sub` |
| `SUB_CRON`         | 自动更新的 cron 表达式                                         | `0 */6 * * *`             |
| `SECRET`           | Dashboard 登录密钥，会自动注入配置                             | `my-password`             |
| `ALLOW_LAN`        | 是否允许局域网连接，默认不修改配置                             | `true` 或 `false`         |
| `TUN_ENABLED`      | 是否启用 TUN 模式，重启后自动恢复（需配合 Docker 权限）        | `true` 或 `false`         |
| `DOWNLOAD_PROXY`   | 首次下载订阅时使用的外部代理（可选）                           | `http://192.168.1.1:7890` |
| `SUB_USER_AGENT`   | 下载订阅时使用的 User-Agent，默认 `clash.meta`（可选）         | `clash.meta`              |

### 工作逻辑

1. **启动时（本地有配置）**：
   - 先用本地配置启动 mihomo
   - 等待代理服务就绪后，通过本地代理 (127.0.0.1:7890) 更新订阅
   - 更新成功后自动重启生效

2. **启动时（本地无配置）**：
   - 先尝试直连下载订阅
   - 直连失败时，如果设置了 `DOWNLOAD_PROXY`，使用外部代理下载
   - 下载成功后启动 mihomo

3. **定时更新**：
   - 如果设置了 `SUB_CRON`，按照 cron 表达式定时更新
   - 通过本地代理下载订阅
   - 更新成功后自动重启 mihomo 生效
   - 更新失败时保持当前配置运行

4. **SECRET 注入**：
   - 如果设置了 `SECRET`，会自动写入配置文件的 `secret` 字段
   - 方便统一管理 Dashboard 密码

5. **ALLOW_LAN 注入**：
   - 如果设置了 `ALLOW_LAN`，会自动写入配置文件的 `allow-lan` 字段
   - 设置为 `true` 允许局域网连接，`false` 禁止

6. **TUN_ENABLED 注入**：
   - 如果设置了 `TUN_ENABLED=true`，每次启动和订阅更新后自动向配置写入 TUN 模式配置段
   - 解决了通过 Dashboard UI 开启 TUN 后重启丢失状态的问题
   - 需要同时在 docker-compose.yml 中开启 `NET_ADMIN` 权限和 `/dev/net/tun` 设备

> **提示**：如果订阅地址需要代理访问且本地没有配置文件，请设置 `DOWNLOAD_PROXY` 指向一个可用的代理。

### 常用 Cron 表达式

| 表达式         | 说明              |
| -------------- | ----------------- |
| `0 */6 * * *`  | 每 6 小时更新     |
| `0 0 * * *`    | 每天凌晨更新      |
| `0 */12 * * *` | 每 12 小时更新    |
| `*/30 * * * *` | 每 30 分钟更新    |
| `0 8 * * *`    | 每天早上 8 点更新 |

### 查看订阅更新日志

```bash
docker exec glash cat /var/log/subscription.log
```

## ⚠️ 配置要求

你的 `config.yaml` 必须包含以下配置才能正常使用 Dashboard：

```yaml
# 允许外部访问 API
external-controller: 0.0.0.0:9090
或者是
external-controller::9090
# 密钥（用于登录dashboard ，可不填，建议填上，提高安全性）
secret: ''
```

## 端口说明

| 端口 | 用途                     |
| ---- | ------------------------ |
| 7890 | HTTP 代理                |
| 7891 | SOCKS5 代理              |
| 7892 | 混合代理 (HTTP + SOCKS5) |
| 9090 | RESTful API & Dashboard  |

## Dashboard 访问

启动后访问：http://127.0.0.1:9090/ui/
![5Q9E9uQk9j6x9tkCSMu9MDxY56MYklUg.webp](https://cdn.nodeimage.com/i/5Q9E9uQk9j6x9tkCSMu9MDxY56MYklUg.webp)

首次访问需要配置：

- 后端地址：`http://127.0.0.1:9090`
- 密钥：与 config.yaml 中的 `secret` 一致

## 配置示例

```yaml
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info

# Dashboard 必需配置
external-controller: 0.0.0.0:9090

proxies:
  - name: '节点名称'
    type: vmess
    server: example.com
    port: 443
    uuid: your-uuid
    # ... 其他配置

proxy-groups:
  - name: '🚀 节点选择'
    type: select
    proxies:
      - 节点名称

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
```

## 界面一览

![kWcCiiHfK3fmyFWQaC6Ndkh0vnfLj0lP.webp](https://cdn.nodeimage.com/i/kWcCiiHfK3fmyFWQaC6Ndkh0vnfLj0lP.webp)
![vA3jgJCQmhsLNVqoNWj8cKvqovJmX4QK.webp](https://cdn.nodeimage.com/i/vA3jgJCQmhsLNVqoNWj8cKvqovJmX4QK.webp)
![zDENCwikV4ZKAxrBwPjKsj3MXUYTpxiR.webp](https://cdn.nodeimage.com/i/zDENCwikV4ZKAxrBwPjKsj3MXUYTpxiR.webp)
![zDENCwikV4ZKAxrBwPjKsj3MXUYTpxiR.webp](https://cdn.nodeimage.com/i/zDENCwikV4ZKAxrBwPjKsj3MXUYTpxiR.webp)
![gvdOcbUtUASmKtlfKY7crcokkIQYY0nM.webp](https://cdn.nodeimage.com/i/gvdOcbUtUASmKtlfKY7crcokkIQYY0nM.webp)

## 常见问题

### Q1：Dashboard 提示"混合内容"（Mixed Content）错误，无法连接后端

**现象**：通过 HTTPS 地址访问 Dashboard（例如 `https://metacubex.github.io/metacubexd/`），填入后端地址 `http://your-server:9090` 后，浏览器报错 `Mixed Content` 并拒绝请求。

**原因**：HTTPS 页面不允许发起 HTTP 请求，属于浏览器安全限制，无法绕过。

**解决方案（推荐）：用反向代理同时代理前端页面和 API**

在服务器上配置 nginx，将同一个 HTTPS 域名同时反代 Dashboard UI 和 mihomo API：

```nginx
server {
    listen 443 ssl;
    server_name your-domain.com;
    # ssl_certificate / ssl_certificate_key 省略

    # 反代 Dashboard UI
    location /ui/ {
        proxy_pass http://127.0.0.1:9090/ui/;
    }

    # 反代 mihomo API（Dashboard 会向同域名发起 API 请求）
    location / {
        proxy_pass http://127.0.0.1:9090/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

配置完成后，通过 `https://your-domain.com/ui/` 访问 Dashboard，后端地址填 `https://your-domain.com`，前端和 API 均走 HTTPS，不再触发混合内容限制。

**备选方案**：直接用 HTTP 地址访问内置 Dashboard，例如 `http://your-server:9090/ui/`，避免 HTTPS 限制。

---

### Q2：订阅下载失败，容器无法启动或一直用旧配置

1. 检查 `SUB_URL` 是否正确，可在宿主机用 `curl -v "$SUB_URL"` 验证是否可以直连访问
2. 如果订阅地址需要代理才能访问，且本地**没有**现成配置文件，请通过 `DOWNLOAD_PROXY` 提供一个可用的外部代理：
   ```bash
   -e DOWNLOAD_PROXY=http://192.168.1.1:7890
   ```
3. 查看容器日志确认具体报错：
   ```bash
   docker logs glash
   ```
4. 查看订阅更新专项日志：
   ```bash
   docker exec glash cat /var/log/subscription.log
   ```

---

### Q3：TUN 模式在 Dashboard 手动开启后，重启容器就失效了

TUN 状态写在运行时内存中，容器重启后不会保留。请通过环境变量持久化：

```yaml
environment:
  - TUN_ENABLED=true
```

同时确保 compose 文件中已添加必要权限：

```yaml
cap_add:
  - NET_ADMIN
devices:
  - /dev/net/tun:/dev/net/tun
```

设置后，每次重启容器都会自动向配置文件注入 TUN 配置段并生效。

---

### Q4：容器启动了，但浏览器打开 `http://127.0.0.1:9090/ui/` 无响应

1. 确认容器正在运行：`docker ps | grep glash`
2. 确认宿主机端口映射正确（9090 已映射）：`docker port glash`
3. 如果是远程服务器，请将 `127.0.0.1` 替换为服务器实际 IP，并确认防火墙已放行 9090 端口
4. 检查配置文件中是否包含 `external-controller: 0.0.0.0:9090`（缺少此配置则 API 不启动）

---

### Q5：挂载了新的 `config.yaml`，但修改不生效

- 使用 `:ro`（只读）模式挂载单个文件时，直接重启容器即可生效
- **使用订阅功能时禁止用 `:ro` 模式**，因为 start.sh 需要向配置文件写入 `secret`、`allow-lan` 等字段
- 若修改配置后容器行为未变化，请先检查挂载路径是否正确：
  ```bash
  docker exec glash cat /root/.config/mihomo/config.yaml | head -5
  ```

---

## 贡献与支持
如果你有好的需求或者发现了一些Bug, 欢迎PR，一起共建开源生态

## Star History

<a href="https://www.star-history.com/?repos=gangz1o%2Fclash4docker&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=gangz1o/clash4docker&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=gangz1o/clash4docker&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=gangz1o/clash4docker&type=date&legend=top-left" />
 </picture>
</a>

### 一些可用docker加速源

```bash
https://docker.1ms.run
https://docker.kejilion.pro
https://docker-registry.nmqu.com
https://docker.xuanyuan.me
https://dockerproxy.net
https://hub.rat.dev
https://hub1.nat.tf
https://hub2.nat.tf
https://hub3.nat.tf
https://hub4.nat.tf
https://mirror.iscas.ac.cn
https://docker.hpcloud.cloud
https://docker.apiba.cn
```

## 版本信息

- **Mihomo**: v1.19.22
- **MetacubexD**: v1.244.2
- **架构**: linux/amd64, linux/arm64

## 社区交流

有问题、有想法，或者就是想和一群搞开发的人聊聊？

- **论坛**：[linux.do](https://linux.do/) —— 来这里讨论、分享你的配置、反馈问题，欢迎常驻。

## 致谢

感谢以下开源项目：

- [Mihomo](https://github.com/MetaCubeX/mihomo) - 强大的代理内核
- [MetacubexD](https://github.com/MetaCubeX/metacubexd) - 现代化 Web Dashboard
  
## License

MIT
