# Clash for Docker（glash）

[![GitHub Stars](https://img.shields.io/github/stars/gangz1o/clash4docker?style=for-the-badge)](https://github.com/gangz1o/clash4docker/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/gangz1o/clash4docker?style=for-the-badge)](https://github.com/gangz1o/clash4docker/forks)
[![GitHub Issues](https://img.shields.io/github/issues/gangz1o/clash4docker?style=for-the-badge)](https://github.com/gangz1o/clash4docker/issues)
[![Docker Pulls](https://img.shields.io/docker/pulls/gangz1o/glash?style=for-the-badge)](https://hub.docker.com/r/gangz1o/glash)

基于 [Mihomo](https://github.com/MetaCubeX/mihomo) 内核、内置 [MetacubexD](https://github.com/MetaCubeX/metacubexd) Dashboard 的多架构 Docker 镜像。

项目同时支持远程订阅和本地配置。订阅下载后会先在候选文件中完成环境变量覆写、自定义 Hook 和 Mihomo 原生校验；全部成功才替换当前配置。定时更新使用 Controller 热加载，失败时保留或恢复旧配置，不会为了更新订阅主动重启容器。

快速导航：[订阅模式](#快速开始订阅模式) · [本地配置](#本地配置模式) · [环境变量](#环境变量) · [订阅更新](#订阅更新机制) · [TUN](#tun-模式) · [自定义 Hook](#订阅后自定义-hook) · [故障排查](#故障排查) · [升级](#升级与版本固定)

## 功能

- Mihomo 与 MetacubexD 已打包进镜像
- 支持 `linux/amd64`、`linux/arm64`、`linux/arm/v7`
- 支持订阅首次下载、定时更新和手动更新
- 订阅更新默认通过当前 Mihomo 本地代理完成
- 下载失败不覆盖当前配置，热加载失败自动恢复旧配置
- 支持固定代理模式、代理端口、Dashboard 密钥和代理认证
- 支持持久开启或关闭 TUN，并可关闭不兼容的 `auto-redirect`
- 支持 DNS 覆写和订阅后自定义 Hook
- 预置 GeoIP、GeoSite 和 Country.mmdb 数据
- 内置健康检查、日志轮转示例和 `tini` 进程管理

## 开始之前

先选择适合自己的模式：

| 使用场景 | 推荐模式 | 配置挂载 | 是否需要 TUN |
| --- | --- | --- | --- |
| 使用机场订阅，希望自动更新 | 订阅模式 | 可写配置目录 | 否 |
| 自己维护完整 `config.yaml` | 本地配置模式 | 单文件可只读挂载 | 否 |
| 应用主动连接 HTTP/SOCKS5 代理 | 以上任一模式 | 均可 | 否 |
| 希望透明接管容器网络命名空间内的流量 | TUN 模式 | 可写配置目录 | 是 |
| 希望将 NAS/服务器作为整个局域网网关 | 高级网络部署 | 取决于平台 | 是，并需额外配置宿主机路由、防火墙和转发 |

> TUN 在 Docker bridge 网络中只修改容器自己的网络命名空间，不会因为开启 `TUN_ENABLED=true` 就自动接管宿主机或整个局域网。大多数用户只需要映射 7890/7891/7892 代理端口，不需要开启 TUN。

## 快速开始：订阅模式

创建 `docker-compose.yml`：

```yaml
services:
  glash:
    image: gangz1o/glash:latest
    container_name: glash
    restart: unless-stopped
    ports:
      - "7890:7890" # HTTP
      - "7891:7891" # SOCKS5
      - "7892:7892" # HTTP + SOCKS5
      - "9090:9090" # Dashboard 与 API
    volumes:
      - ./config:/root/.config/mihomo
    environment:
      TZ: Asia/Shanghai
      SUB_URL: https://your-subscription-url
      SUB_CRON: "0 */6 * * *"
      SECRET: change-this-dashboard-secret
      ALLOW_LAN: "true"
      HTTP_PORT: "7890"
      SOCKS_PORT: "7891"
      MIXED_PORT: "7892"
```

启动并查看日志：

```bash
docker compose up -d
docker logs -f glash
```

配置目录必须可写。订阅模式不要把 `config.yaml` 单文件挂载为 `:ro`，因为容器需要保存订阅并写入环境变量覆写项。

### Docker Run

```bash
docker run -d \
  --name glash \
  --restart unless-stopped \
  -p 7890:7890 \
  -p 7891:7891 \
  -p 7892:7892 \
  -p 9090:9090 \
  -v /path/to/config:/root/.config/mihomo \
  -e SUB_URL=https://your-subscription-url \
  -e 'SUB_CRON=0 */6 * * *' \
  -e SECRET=change-this-dashboard-secret \
  -e ALLOW_LAN=true \
  -e HTTP_PORT=7890 \
  -e SOCKS_PORT=7891 \
  -e MIXED_PORT=7892 \
  gangz1o/glash:latest
```

## 本地配置模式

本地模式不会下载订阅，适合已经拥有完整 Mihomo 配置的用户：

```yaml
services:
  glash:
    image: gangz1o/glash:latest
    container_name: glash
    restart: unless-stopped
    ports:
      - "7890:7890"
      - "7891:7891"
      - "7892:7892"
      - "9090:9090"
    volumes:
      - ./config.yaml:/root/.config/mihomo/config.yaml:ro
    environment:
      TZ: Asia/Shanghai
```

最小配置至少需要一个代理端口、`proxies` 或 `proxy-providers`，以及 Dashboard 所需的 Controller：

```yaml
mixed-port: 7892
allow-lan: true
mode: rule
external-controller: 0.0.0.0:9090
secret: "change-this-dashboard-secret"

proxies:
  # 你的节点

proxy-groups:
  # 你的代理组

rules:
  - MATCH,DIRECT
```

完整结构可参考 [`config.example.yaml`](./config.example.yaml)。

> 本地单文件使用 `:ro` 时不要设置会修改配置的环境变量，例如 `SECRET`、`MODE`、端口覆写、`TUN_ENABLED` 或 `DNS_OVERRIDE`。需要这些能力时请改为挂载可写目录。

## Dashboard

浏览器访问：

```text
http://<Docker 宿主机 IP>:9090/ui/
```

首次进入时填写：

| 项目 | 填写内容 |
| --- | --- |
| 后端地址 | `http://<Docker 宿主机 IP>:9090` |
| 密钥 | 与 `SECRET` 或配置文件中的 `secret` 一致 |

只有浏览器本身运行在 Docker 宿主机上时，才能使用 `http://127.0.0.1:9090`。从另一台电脑或手机访问 NAS 时，`127.0.0.1` 指向的是电脑或手机自己，必须填写 NAS 的实际 IP。

如果使用 HTTPS 域名访问 Dashboard，后端也必须使用 HTTPS，否则浏览器会拦截 HTTP API 请求并提示 Mixed Content。可使用 Nginx、Caddy 等反向代理，让 `/ui/` 和 Mihomo API 使用同一个 HTTPS 域名。

## 使用代理

### 宿主机或局域网设备

先设置 `ALLOW_LAN=true`，然后使用 Docker 宿主机 IP：

```text
HTTP:   http://192.168.1.10:7890
SOCKS5: socks5://192.168.1.10:7891
Mixed:  192.168.1.10:7892
```

可用 curl 验证：

```bash
curl -x http://192.168.1.10:7890 https://www.gstatic.com/generate_204
curl --proxy socks5h://192.168.1.10:7891 https://www.gstatic.com/generate_204
```

### 其他 Docker 容器

让两个容器加入同一个用户自定义 Docker 网络后，使用服务名连接，不要使用 `127.0.0.1`：

```text
HTTP_PROXY=http://glash:7890
HTTPS_PROXY=http://glash:7890
ALL_PROXY=socks5h://glash:7891
```

### 代理端口认证

`AUTHENTICATION` 会写入 Mihomo 的全局 `authentication`，适用于 HTTP、SOCKS5 和 Mixed 代理端口：

```yaml
environment:
  AUTHENTICATION: "alice:password,bob:another-password"
```

使用带认证的 HTTP 代理：

```bash
curl -x http://alice:password@192.168.1.10:7890 https://www.gstatic.com/generate_204
```

认证不是流量加密。不要只依靠用户名和密码把代理端口直接暴露到互联网，应同时使用防火墙、可信网络或 VPN。

## 环境变量

未设置的可选覆写项会保留订阅或本地配置中的原值。

### 运行环境

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | 容器时区，也决定 cron 的执行时间 |
| `SAFE_PATHS` | 空 | 追加传给 Mihomo 的安全路径，多个容器内路径用冒号分隔；仅在配置引用挂载目录时需要 |

### 订阅与更新

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SUB_URL` | 空 | 返回 Mihomo/Clash YAML 配置的 HTTP(S) 订阅地址 |
| `SUB_CRON` | 空 | 5 段 cron 表达式；为空时不自动更新 |
| `DOWNLOAD_PROXY` | 空 | 首次下载无法直连、且没有可用本地配置时使用的外部代理 |
| `SUB_USER_AGENT` | `clash.meta` | 下载订阅使用的 User-Agent |

常用定时表达式：

| 表达式 | 含义 |
| --- | --- |
| `0 */6 * * *` | 每 6 小时 |
| `0 0 * * *` | 每天 00:00 |
| `0 */12 * * *` | 每 12 小时 |
| `*/30 * * * *` | 每 30 分钟 |
| `0 8 * * *` | 每天 08:00 |

### 持久覆写

这些值会在启动和每次订阅更新时重新写入，避免 Dashboard 临时修改或机场订阅内容在重启后覆盖用户选择。

| 变量 | 可选值 | 说明 |
| --- | --- | --- |
| `SECRET` | 任意单行字符串 | Dashboard/API 密钥；使用定时更新时应与运行中配置一致 |
| `ALLOW_LAN` | `true` / `false` | 是否允许局域网访问代理端口 |
| `MODE` | `rule` / `global` / `direct` | 固定 Mihomo 运行模式 |
| `HTTP_PORT` | `1`–`65535` | 覆写顶层 `port` |
| `SOCKS_PORT` | `1`–`65535` | 覆写顶层 `socks-port` |
| `MIXED_PORT` | `1`–`65535` | 覆写顶层 `mixed-port` |
| `AUTHENTICATION` | `user:pass[,user:pass]` | HTTP、SOCKS5、Mixed 代理认证 |
| `DNS_OVERRIDE` | `true` / `false` | 为 `true` 时用项目预设完整覆写顶层 `dns` 配置 |
| `TUN_ENABLED` | `true` / `false` | 持久开启或关闭顶层 `tun` 配置 |
| `TUN_AUTO_REDIRECT` | `true` / `false` | `TUN_ENABLED=true` 时控制 `auto-redirect`；未设置时为 `true` |
| `FORCE_UNIFIED_DELAY_AND_TCP_CONCURRENT` | `true` / `false` | 订阅缺少 `unified-delay`、`tcp-concurrent` 时会补为 `true`；设为 `true` 时也覆写已有值 |

### 端口映射规则

Docker 端口格式是 `宿主机端口:容器端口`，右侧必须与 Mihomo 最终配置一致。例如希望外部继续使用 7890，但容器内 HTTP 端口固定为 17890：

```yaml
ports:
  - "7890:17890"
environment:
  HTTP_PORT: "17890"
```

推荐直接把容器内端口固定为项目默认值，这样订阅即使携带其他端口也不会破坏映射：

```yaml
ports:
  - "7890:7890"
  - "7891:7891"
  - "7892:7892"
environment:
  HTTP_PORT: "7890"
  SOCKS_PORT: "7891"
  MIXED_PORT: "7892"
```

## 订阅更新机制

### 启动时没有本地配置

1. 尝试直连 `SUB_URL`。
2. 直连失败且设置了 `DOWNLOAD_PROXY` 时，尝试外部代理。
3. 下载内容通过基础检查、环境覆写、Hook 和 Mihomo 原生校验后才会安装。
4. 所有候选配置都不可用时容器退出，不会留下无效配置。

### 启动时已有本地配置

1. 先尝试直连获取新订阅。
2. 如果直连不可用，使用现有配置启动 Mihomo。
3. 等待本地代理就绪，再通过当前 HTTP 或 Mixed 代理更新订阅。
4. 更新失败时继续运行现有配置。
5. 如果现有配置也无法启动，最后尝试 `DOWNLOAD_PROXY`。

### 定时更新

1. 检查 `http://127.0.0.1:9090/version` 和 `SECRET` 鉴权。
2. 使用当前配置中的 HTTP 或 Mixed 端口作为本地代理下载订阅。
3. 在候选文件中执行覆写、Hook、基础校验和 Mihomo 原生校验。
4. 安装候选配置并调用 Controller 热加载，不终止 Mihomo 进程。
5. 热加载失败时恢复旧配置并执行补偿加载。
6. 文件锁会阻止两个更新任务同时修改配置。

专项日志：

```bash
docker exec glash cat /var/log/subscription.log
```

### 手动更新

设置 `SUB_URL` 后，即使没有配置 `SUB_CRON`，容器也会生成手动更新命令：

```bash
docker exec glash /app/update_sub.sh
```

手动更新与定时更新使用相同的本地代理、校验、Hook、热加载和失败恢复流程。它要求 Mihomo 已经运行，并且 `SECRET` 与运行中的 Controller 配置一致。

## TUN 模式

TUN 需要 Linux TUN 设备和 `NET_ADMIN` 能力：

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
      - "7890:7890"
      - "7891:7891"
      - "7892:7892"
      - "9090:9090"
    volumes:
      - ./config:/root/.config/mihomo
    environment:
      SUB_URL: https://your-subscription-url
      TUN_ENABLED: "true"
```

项目注入的默认 TUN 配置为：

```yaml
tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true
```

如果日志出现以下错误，通常是 NAS 内核、netlink、iptables/nftables 与 `auto-redirect` 不兼容：

```text
Start TUN listening error: auto redirect ... netlink receive ...
```

可关闭自动重定向后重建容器：

```yaml
environment:
  TUN_ENABLED: "true"
  TUN_AUTO_REDIRECT: "false"
```

```bash
docker compose up -d --force-recreate
```

### Docker 网络边界

- bridge 模式：TUN 路由位于 glash 容器自己的网络命名空间，只影响该命名空间。
- 其他容器：通常应显式配置 `HTTP_PROXY`、`HTTPS_PROXY` 或 `ALL_PROXY`，而不是期待 glash 的 TUN 自动接管它们。
- 宿主机和局域网网关：需要宿主机网络命名空间、IP forwarding、防火墙/NAT 和正确的默认网关设置；不同 NAS 系统限制不同，本项目的一个环境变量无法代替这些系统配置。
- `network_mode: host` 会直接影响宿主网络，应了解路由和防火墙后再使用；host 模式下不要再配置 `ports`。

不要只用 `ping` 判断代理是否正常。普通 HTTP/SOCKS5 代理不代理 ICMP，部分远端也会丢弃 ICMP；优先使用前文的 `curl` 命令验证。

## 订阅后自定义 Hook

订阅模式可以把可执行脚本挂载到 `/app/hooks.d`。每个脚本收到候选配置路径作为第一个参数，按文件名顺序执行；任一 Hook 失败都会取消本次更新，不覆盖当前配置。

```yaml
volumes:
  - ./config:/root/.config/mihomo
  - ./hooks.d:/app/hooks.d:ro
```

Hook 只对订阅下载和更新生效，不会修改纯本地模式的配置。

### 示例：让 PT 端口直连

创建 `hooks.d/10-direct-pt-ports.sh`：

```bash
#!/bin/bash
set -e

config_file="$1"
temp_file="${config_file}.hook.$$"
trap 'rm -f "${temp_file}"' EXIT

awk '
    function add_rules() {
        print "  - SRC-PORT,6881,DIRECT"
        print "  - DST-PORT,6881,DIRECT"
        print "  - SRC-PORT,51413,DIRECT"
        print "  - DST-PORT,51413,DIRECT"
    }
    !inserted && /^rules:[[:space:]]*$/ {
        print
        add_rules()
        inserted = 1
        next
    }
    !inserted && /^rules:[[:space:]]*\[\][[:space:]]*$/ {
        print "rules:"
        add_rules()
        inserted = 1
        next
    }
    !inserted && /^rules:/ {
        print "不支持内联 rules，请改为 YAML 列表格式" > "/dev/stderr"
        exit 2
    }
    { print }
    END {
        if (!inserted) {
            print "rules:"
            add_rules()
        }
    }
' "${config_file}" > "${temp_file}"

mv "${temp_file}" "${config_file}"
```

赋予执行权限并重建容器：

```bash
chmod +x hooks.d/10-direct-pt-ports.sh
docker compose up -d --force-recreate
docker exec glash /app/update_sub.sh
```

如果 qBittorrent 或 Transmission 独占一个容器 IP/局域网 IP，使用 `SRC-IP-CIDR,<IP>/32,DIRECT` 通常比端口规则更完整，因为 BitTorrent 会连接大量不同目标端口。

## 运维命令

```bash
# 容器状态与健康检查
docker ps --filter name=glash
docker inspect glash --format '{{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} restart={{.RestartCount}} oom={{.State.OOMKilled}}'

# 主日志
docker logs --tail=200 glash

# 订阅更新日志
docker exec glash tail -n 200 /var/log/subscription.log

# 当前生效的关键配置
docker exec glash sh -c "grep -E '^(port|socks-port|mixed-port|allow-lan|mode|external-controller|secret|authentication|tun|dns):' /root/.config/mihomo/config.yaml"

# Controller 是否可访问；配置 SECRET 时添加 Authorization 请求头
curl http://127.0.0.1:9090/version
curl -H 'Authorization: Bearer your-secret' http://127.0.0.1:9090/version

# Mihomo 原生配置校验
docker exec glash /app/mihomo -t -d /root/.config/mihomo -f /root/.config/mihomo/config.yaml

# 手动更新订阅
docker exec glash /app/update_sub.sh
```

## 故障排查

### Dashboard 提示“无法连接后端”

按顺序检查：

1. 从其他电脑或手机访问时，后端地址不能填 `127.0.0.1`，应填 `http://NAS-IP:9090`。
2. 运行 `docker port glash`，确认 9090 已映射。
3. 运行 `curl http://NAS-IP:9090/version`；设置密钥时加 Bearer 请求头。
4. 确认配置包含 `external-controller: 0.0.0.0:9090`。
5. 确认 Dashboard 中填写的密钥与 `SECRET` 一致。
6. HTTPS 页面不能连接 HTTP 后端；统一使用 HTTP，或给 UI 和 API 配置同域 HTTPS 反向代理。

### 容器正常，但 7890/7891/7892 无法连接

1. 确认 `ALLOW_LAN=true`。
2. 查看有效配置中的 `port`、`socks-port`、`mixed-port`。
3. Docker 映射右侧端口必须等于 Mihomo 容器内端口。
4. 机场订阅会修改端口时，设置 `HTTP_PORT`、`SOCKS_PORT`、`MIXED_PORT` 固定端口。
5. 检查宿主机防火墙；不要把代理端口直接暴露到公网。

### Dashboard 修改 Mixed 端口后，重启又变成 0 或原值

Dashboard 的修改是运行态配置，订阅刷新和容器重启可能重新加载磁盘配置。使用环境变量持久设置：

```yaml
environment:
  MIXED_PORT: "7892"
```

HTTP 和 SOCKS5 端口分别使用 `HTTP_PORT`、`SOCKS_PORT`。

### 订阅下载失败、下载到 HTML 或一直使用旧配置

1. 在宿主机运行 `curl -v '订阅地址'` 检查地址和响应。
2. 某些订阅依赖特定 User-Agent，可设置 `SUB_USER_AGENT`。
3. 首次启动没有本地配置、且订阅必须走代理时，设置 `DOWNLOAD_PROXY`。
4. 已有配置时，确认当前 HTTP 或 Mixed 端口能够访问网络。
5. 查看 `/var/log/subscription.log` 中的基础校验、Mihomo 校验或 Hook 错误。
6. 新订阅失败不会替换当前可用配置，这是预期的容错行为。

### 手动或定时更新提示 Controller/SECRET 错误

更新前会访问 9090 Controller。确保：

- 有 `external-controller: 0.0.0.0:9090`
- `SECRET` 与运行中配置的 `secret` 完全相同
- 9090 没被其他进程占用
- 本地请求没有被 `HTTP_PROXY` 等宿主环境变量劫持；项目内部请求已主动绕过代理

### 定时更新时出现 `Mihomo shutting down` 或容器重启

旧版本通过终止并重启 Mihomo 应用订阅，可能让 PID 1 退出。该流程从 v2.2.3 起已改为 Controller 热加载。升级并强制重建：

```bash
docker compose pull
docker compose up -d --force-recreate
```

随后检查实际镜像和容器启动时间，避免仍在运行旧容器。

### TUN 开启失败或局域网设备仍无法访问代理

1. 确认存在 `/dev/net/tun`，并已添加 `NET_ADMIN` 和设备映射。
2. 出现 `auto redirect`、`netlink`、`numerical result out of range` 时设置 `TUN_AUTO_REDIRECT=false`。
3. bridge 模式中的 TUN 不会自动接管宿主机或局域网流量。
4. 将 NAS 设为局域网网关还需要系统级 IP 转发、路由、防火墙/NAT；请按 NAS 系统文档检查。
5. 不要以 `ping` 作为唯一验证，改用 HTTP/SOCKS5 `curl` 测试。

### qBittorrent、Transmission 或 PT 入站异常

1. 如果客户端显式设置了代理，确认是否需要为 BT 流量关闭代理。
2. TUN/透明代理场景可用 `SRC-PORT`、`DST-PORT` 规则直连；订阅模式通过 Hook 持久注入。
3. 独立容器或独立设备优先按源 IP 设置 `SRC-IP-CIDR,...,DIRECT`。
4. 入站端口还需要在路由器、宿主机防火墙和 Docker 中正确转发；Mihomo 分流规则不能代替端口映射。

### 内存持续增长或容器被系统杀掉

先区分“连接数增长”“内核内存未释放”和“Docker OOM”：

```bash
docker stats --no-stream glash
docker inspect glash --format 'oom={{.State.OOMKilled}} exit={{.State.ExitCode}} restart={{.RestartCount}}'
docker logs --tail=300 glash
```

同时在 Dashboard 查看活跃连接数。如果存在数万连接，先定位产生连接的客户端、BT/PT 程序或可能的 TUN 路由回环；连接数与内存一起增长并不等于已经证明内存泄漏。

若升级到最新镜像后仍可复现，请在 issue 中提供：镜像标签、Mihomo 版本、CPU 架构、NAS/系统、完整 compose（隐去订阅和密码）、是否开启 TUN、问题前后的连接数与内存、`OOMKilled`、订阅更新时间及相关日志。

### 配置文件修改或环境覆写不生效

1. 订阅模式必须挂载可写目录，不能只读挂载单个文件。
2. 检查实际挂载内容：`docker exec glash head -n 30 /root/.config/mihomo/config.yaml`。
3. 环境变量修改后需要重建容器：`docker compose up -d --force-recreate`。
4. Dashboard 修改可能在下一次订阅更新后被环境变量覆写，这是持久覆写的设计行为。
5. Hook 只在订阅流程执行，纯本地配置模式不会运行 Hook。

## 升级与版本固定

升级 latest：

```bash
docker compose pull
docker compose up -d --force-recreate
```

生产环境建议固定镜像标签，并在验证后主动升级：

```yaml
image: gangz1o/glash:x.y.z
```

当前源码构建参数见 [`Dockerfile`](./Dockerfile)：

| 组件 | 当前版本 |
| --- | --- |
| Alpine | 3.19 |
| Mihomo | v1.19.30 |
| MetacubexD | v1.273.0 |

镜像内页面显示的版本取决于所使用的镜像标签，不一定与 `master` 分支当前值相同。

## 运行时结构

```text
start.sh                         # 轻量入口
lib/glash/
├── app.sh                       # 启动流程编排
├── common.sh                    # 日志与文件操作
├── config.sh                    # 配置校验和变换
├── cron.sh                      # 手动/定时更新任务
├── environment.sh               # 环境变量规范化与校验
├── hooks.sh                     # 订阅后 Hook
├── mihomo.sh                    # Mihomo 进程和热加载
└── subscription.sh              # 下载、锁和更新事务
```

## 本地开发与验证

```bash
# Shell 语法
for script in start.sh lib/glash/*.sh tests/*.sh; do bash -n "$script"; done

# 回归测试
bash tests/test_mode.sh
bash tests/test_reload.sh
bash tests/test_modules.sh

# 构建镜像
docker build -t clash4docker-local .

# 容器烟雾测试
bash tests/test_container.sh clash4docker-local
```

Pull Request 会运行 Shell 测试、AMD64 容器烟雾测试和多架构构建检查，详情见 [`docs/ci.md`](./docs/ci.md)。

## 社区与贡献

有问题或建议可以提交 [Issue](https://github.com/gangz1o/clash4docker/issues)。提交前请先搜索本 README 的故障现象和已有 issue，并附上“内存持续增长”一节列出的环境与日志信息。

- 论坛：[linux.do](https://linux.do/)
- Mihomo 配置文档：[wiki.metacubex.one](https://wiki.metacubex.one/)

## Star History

[![Star History Chart](https://star-history.dera.page/svg?repos=gangz1o/clash4docker&type=date&legend=top-left)](https://star-history.dera.page/#gangz1o/clash4docker&type=date&legend=top-left)

## 致谢

感谢以下开源项目：

- [Mihomo](https://github.com/MetaCubeX/mihomo)
- [MetacubexD](https://github.com/MetaCubeX/metacubexd)

<!-- DolOffer 赞助广告开始 -->
<div align="center">
  <table border="0">
    <tr>
      <td align="center" bgcolor="#f6f8fa" style="padding: 20px; border-radius: 8px; border: 1px solid #d0d7de;">
        <a href="https://doloffer.com" target="_blank">
          <img src="https://cdn.nodeimage.com/i/MbENUNiyjRdvIRrt0GjLTv6mhi41zPO0.webp" alt="DolOffer Logo" height="160"/>
        </a>
        <p align="left" style="font-size: 15px; color: #24292f; margin: 10px 0;">
          全网超划算的 <b>ChatGPT Plus / Claude Pro</b> 会员充值平台。多通道稳定续费，售后无忧。
        </p>
        <p align="left" style="font-size: 14px; color: #57606a;">
          🎁 专属 <b>9 折</b> 优惠码：<code>ai8888</code><br>
          🔗 <a href="https://doloffer.com" target="_blank"><b>DolOffer 官方网站</b></a> ｜ <a href="https://github.com/doloffer-g/guide" target="_blank"><b>使用指南</b></a>
        </p>
      </td>
    </tr>
  </table>
</div>
<!-- DolOffer 赞助广告结束 -->

## License

MIT
