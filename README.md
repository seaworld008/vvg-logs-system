# VVG 日志收集系统

VVG (Vector → VictoriaLogs → Grafana) 是一个高性能的日志收集、存储和可视化解决方案。

## 🏗️ 系统架构

```
┌─────────────────────┐    ┌──────────────────────┐     ┌─────────────────────┐
│                     │    │                      │     │                     │
│      Vector         │────│    VictoriaLogs      │──── │      Grafana        │
│   (日志收集器)       │    │     (日志存储)       │     │    (日志可视化)      │
│                     │    │                      │     │                    │
│  • Nginx 日志       │    │  • 高性能存储         │     │  • 查询界面         │
│  • Java 多行日志    │    │  • 数据压缩           │     │  • 仪表板           │
│  • 数据处理和转换    │    │  • 快速检索           │    │  • 告警功能          │
│                     │    │                      │    │                     │
└─────────────────────┘    └──────────────────────┘    └─────────────────────┘
         :8686                       :9428                       :3000
```

## ✨ 核心特性

- **🚀 高性能**: VictoriaLogs 提供极高的写入和查询性能
- **📦 轻量级**: 相比 ELK 栈，资源占用更少
- **🔧 易部署**: Docker Compose 一键部署，vector支持kubernetes分布式部署
- **📊 可视化**: Grafana 提供强大的日志查询和可视化功能
- **🔍 智能解析**: 自动识别 Nginx 和 Java 日志格式
- **🔄 高可用**: 支持多实例部署和负载均衡

## 📋 支持的日志格式

### Nginx 日志
- **Access Log**: 标准格式和 JSON 格式
- **Error Log**: 标准错误日志格式
- **自定义格式**: 支持自定义 log_format

### Java 应用日志
- **单行日志**: 标准 Java 应用日志
- **多行日志**: 异常堆栈、调试信息等
- **JSON 格式**: 结构化 Java 日志

## 🚀 快速开始

本系统支持多种部署方式，可根据实际环境选择合适的部署架构。

### 部署架构选择

**选项 1: 单机部署**
- 所有组件部署在同一台服务器
- 适合测试环境或小规模应用

**选项 2: 分布式部署** (推荐)
- VictoriaLogs: 部署在存储服务器
- Grafana: 部署在展示服务器  
- Vector: 部署在各个应用服务器

**选项 3: Kubernetes 部署** ⭐ 新增
- 适合容器化环境和微服务架构
- 支持 Docker CRI 和 Containerd CRI
- 专门优化的 Java 多行日志收集配置

### 部署步骤

#### 1. 部署 VictoriaLogs (日志存储)

```bash
cd docker-compose/victorialogs
cp env.example .env
# 编辑 .env 文件设置相关参数
sudo mkdir -p /data/victorialogs/victoria-logs-data
docker-compose up -d
```

详细说明: [VictoriaLogs 部署文档](docker-compose/victorialogs/README.md)

#### 2. 部署 Grafana (可视化界面)

```bash
cd docker-compose/grafana
cp env.example .env
# 编辑 .env 文件，设置 VictoriaLogs 服务器地址
sudo mkdir -p /data/grafana/grafana-data
sudo chown 472:472 /data/grafana/grafana-data
docker-compose up -d
```

详细说明: [Grafana 部署文档](docker-compose/grafana/README.md)

#### 3. 部署 Vector (日志收集)

在每台需要收集日志的应用服务器上:

```bash
cd docker-compose/vector
cp env.example .env
# 编辑 .env 文件，设置 VictoriaLogs 服务器地址和日志路径
sudo mkdir -p /data/vector-docker/vector_data
docker-compose up -d
```

详细说明: [Vector 部署文档](docker-compose/vector/README.md)

#### 4. Kubernetes 部署 (可选) ⭐

在 Kubernetes 环境中部署 Vector 进行日志收集:

```bash
# 1. 修改 VictoriaLogs 地址
cd k8s-deployment
# 编辑配置文件，设置 VictoriaLogs 服务器地址

# 2. 根据容器运行时选择配置文件
# Docker CRI
kubectl apply -f vector-k8s-docker-cri.yaml

# Containerd CRI  
kubectl apply -f vector-k8s-containerd-cri.yaml

# 3. 验证部署
kubectl get pods -n logging
```

详细说明: [Kubernetes 部署文档](k8s-deployment/README.md)

### 验证部署

1. **检查 VictoriaLogs**
```bash
curl http://VictoriaLogs_IP:9428/metrics
```

2. **访问 Grafana**
```bash
# 浏览器访问
http://Grafana_IP:3000
# 默认账号: admin / 在.env中设置的密码
```

3. **检查 Vector 状态**
```bash
# Docker Compose 部署
curl http://Vector_IP:8686/health

# Kubernetes 部署
kubectl get pods -n logging
kubectl logs -n logging -l app=vector --tail=50
```

## 📁 项目结构

```
├── docker-compose/                 # Docker Compose 配置
│   ├── victorialogs/              # VictoriaLogs 日志存储
│   │   ├── docker-compose.yml
│   │   ├── env.example           # 环境变量配置模板
│   │   └── README.md             # 部署说明
│   ├── grafana/                   # Grafana 可视化
│   │   ├── docker-compose.yml
│   │   ├── env.example
│   │   ├── datasources/          # 数据源配置
│   │   ├── dashboards/           # 仪表板配置
│   │   └── README.md
│   └── vector/                    # Vector 日志收集
│       ├── docker-compose.yml
│       ├── env.example
│       ├── vector.yaml           # Vector 配置文件
│       └── README.md
├── k8s-deployment/                 # Kubernetes 部署配置 ⭐
│   ├── vector-k8s-docker-cri.yaml    # Docker CRI 环境配置
│   ├── vector-k8s-containerd-cri.yaml # Containerd CRI 环境配置
│   └── README.md                  # K8S 部署说明
├── docs/                          # 文档目录
│   └── troubleshooting.md        # 故障排查指南
├── LICENSE                        # 开源协议
└── README.md                      # 项目说明
```

## ⚙️ 配置说明

### 环境变量配置

每个服务的配置文件都位于对应目录下的 `env.example`，使用前需要复制为 `.env` 并修改相关参数:

- **VictoriaLogs**: 端口、数据保留期、存储路径
- **Grafana**: VictoriaLogs 地址、管理员密码、端口  
- **Vector (Docker Compose)**: VictoriaLogs 地址、日志文件路径、主机标识
- **Vector (Kubernetes)**: VictoriaLogs 地址、Java 多行日志规则、资源限制

### 网络配置

各服务默认使用 `vvg-monitoring` 网络。分布式部署时，确保:
- VictoriaLogs 的 9428 端口可被 Grafana 和 Vector 访问
- Grafana 的 3000 端口可被用户访问
- Kubernetes 环境中 Vector 能访问 VictoriaLogs 服务
- 配置正确的防火墙规则

## 🔧 自定义配置

### 日志格式定制

编辑相应的配置文件可以:

**Docker Compose 部署**:
- 编辑 `docker-compose/vector/vector.yaml`

**Kubernetes 部署**:
- 编辑 `k8s-deployment/vector-k8s-*.yaml` 中的 ConfigMap

支持的自定义内容:
- 添加新的日志源
- 修改日志解析规则  
- 自定义数据处理逻辑
- 配置日志过滤条件
- Java 多行日志匹配规则

### 性能调优

根据数据量调整:
- VictoriaLogs 内存限制和查询参数
- Vector 批处理大小和缓冲区配置
- Grafana 查询超时和缓存设置

## 📖 文档

- [故障排查指南](docs/troubleshooting.md)
- [VictoriaLogs 部署说明](docker-compose/victorialogs/README.md)
- [Grafana 部署说明](docker-compose/grafana/README.md)  
- [Vector 部署说明](docker-compose/vector/README.md)
- [Kubernetes 部署说明](k8s-deployment/README.md) ⭐

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本项目采用 [MIT 许可证](LICENSE)。

## 🔗 相关链接

- [VictoriaLogs 官方文档](https://docs.victoriametrics.com/VictoriaLogs/)
- [Vector 官方文档](https://vector.dev/docs/)
- [Grafana 官方文档](https://grafana.com/docs/)

---

**注意**: 生产环境部署前请仔细阅读各服务的部署文档，确保正确配置安全和性能参数。 
