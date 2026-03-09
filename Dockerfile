# glash - Clash Docker 镜像
# 基于最新 Mihomo 内核 + MetacubexD Dashboard
# 作者: gangz1o

FROM --platform=$BUILDPLATFORM alpine:3.19 AS builder

# 设置版本变量
ARG MIHOMO_VERSION=v1.19.20
ARG METACUBEXD_VERSION=v1.241.3
ARG TARGETPLATFORM
ARG TARGETARCH

# 安装构建依赖
RUN apk add --no-cache curl unzip ca-certificates

WORKDIR /build

# 根据目标架构下载对应的 mihomo 二进制
RUN case "${TARGETARCH}" in \
        "amd64") ARCH="amd64-compatible" ;; \
        "arm64") ARCH="arm64" ;; \
        "arm") ARCH="armv7" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    echo "Downloading mihomo for ${ARCH}..." && \
    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${ARCH}-${MIHOMO_VERSION}.gz" -o mihomo.gz && \
    gunzip mihomo.gz && \
    chmod +x mihomo

# 下载 MetacubexD Dashboard (前端资源与架构无关)
RUN curl -fsSL "https://github.com/MetaCubeX/metacubexd/releases/download/${METACUBEXD_VERSION}/compressed-dist.tgz" -o dashboard.tgz && \
    mkdir -p /build/ui && \
    tar -xzf dashboard.tgz -C /build/ui

# 下载 GeoIP 和 GeoSite 数据库（预打包，避免运行时下载问题）
RUN mkdir -p /build/geodata && \
    echo "Downloading GeoIP database..." && \
    curl -fsSL "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" -o /build/geodata/geoip.metadb && \
    echo "Downloading GeoSite database..." && \
    curl -fsSL "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat" -o /build/geodata/geosite.dat && \
    echo "Downloading Country.mmdb..." && \
    curl -fsSL "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb" -o /build/geodata/country.mmdb

# 最终镜像
FROM alpine:3.19

LABEL maintainer="gangz1o"
LABEL version="1.2.0"
LABEL description="Clash Docker with Mihomo Core and MetacubexD Dashboard - Subscription Support"

# 安装运行时依赖
# curl: 用于下载订阅配置
# sed/grep: 用于处理配置文件
RUN apk add --no-cache ca-certificates tzdata bash tini curl sed grep && \
    mkdir -p /root/.config/mihomo /app/ui /app/geodata /var/log

# 从构建阶段复制文件
COPY --from=builder /build/mihomo /app/mihomo
COPY --from=builder /build/ui /app/ui
# Geodata 放在 /app/geodata，启动时复制到配置目录
COPY --from=builder /build/geodata /app/geodata

# 复制启动脚本
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# 设置环境变量
ENV TZ=Asia/Shanghai
ENV MIHOMO_CONFIG_DIR=/root/.config/mihomo
# 订阅相关环境变量（可选）
# SUB_URL: 订阅地址
# SUB_CRON: 定时更新 cron 表达式，如 "0 */6 * * *" 表示每6小时更新
# SECRET: Dashboard 登录密钥
# DOWNLOAD_PROXY: 首次下载订阅时使用的代理（本地无配置时）
ENV SUB_URL=""
ENV SUB_CRON=""
ENV SECRET=""
ENV DOWNLOAD_PROXY=""

# 暴露端口
# 7890: HTTP 代理
# 7891: SOCKS5 代理  
# 7892: 混合代理 (HTTP + SOCKS5)
# 9090: API 控制器
EXPOSE 7890 7891 7892 9090

# 挂载配置目录
VOLUME ["/root/.config/mihomo"]

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:9090/version || exit 1

# 使用 tini 作为 init 进程
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/start.sh"]
