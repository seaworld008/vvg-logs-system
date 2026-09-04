# VVG 日志收集系统

VVG 是本仓库的核心日志系统，面向应用原始日志检索、Java 多行日志、message 多条件过滤和可视化排障。主链路为：

```text
Vector -> VictoriaLogs -> Grafana
```

面向 AI Agent 的受控只读查询链路为：

```text
MCP Client -> mcp-victorialogs -> vmauth -> VictoriaLogs
```

核心验证基线：Vector `0.58.0`、VictoriaLogs `v1.52.0`、Grafana `13.2.0-ubuntu`、VictoriaLogs datasource `0.31.0`、Business Text `6.3.0`、VictoriaLogs MCP `v1.9.0`、vmauth `v1.151.0`。Grafana 插件采用版本化宿主机 release 目录和只读挂载，与 Grafana 镜像解耦，正式启动不联网安装。

仓库后半部分另提供独立的 [Gateway 结构化日志分析附加方案](#附加方案gateway-结构化日志分析)。该方案使用 ClickHouse，不与 VVG 的 VictoriaLogs 原始日志链路混合部署或混合变更。

## 日志链路选型

仓库同时长期保留直写与 AutoMQ 缓冲方案，不因生产只启用其中一条而删除其他配置：

| 日志 | 小到中等规模 | 中大规模或需要集中缓冲 |
|---|---|---|
| VVG | [Vector 直写 VictoriaLogs](k8s-deployment/vector/vvg/direct-containerd.yaml) | [Vector 写 AutoMQ](k8s-deployment/vector/vvg/automq-containerd-production.yaml) -> consumer -> VictoriaLogs |
| Gateway | [Vector 直写 ClickHouse](k8s-deployment/vector/gateway/direct-containerd.yaml) | [Vector 写 AutoMQ](k8s-deployment/vector/gateway/automq-containerd-production.yaml) -> consumer -> ClickHouse |

VVG 直写基线位于 `k8s-deployment/vector/vvg/direct-containerd.yaml`，Gateway 直写基线位于
`k8s-deployment/vector/gateway/direct-containerd.yaml`。它们既是较小规模环境的推荐配置，
也是 AutoMQ 主链路的第一回滚入口，必须与缓冲层方案一起维护和验证。

完整替换项、Secret、部署、切换和回滚命令见
[日志链路选型与 Kubernetes 快速启用指南](docs/log-pipeline-selection.md)。仓库保留全部
通用方案；生产管理服务器顶层只保留当前启用清单，旧现场文件带 SHA-256归档。

![AutoMQ 原生夜莺大屏脱敏预览](docs/images/automq-dashboard-overview.png)

上图使用示例值展示 AutoMQ 原生夜莺大屏结构；不包含生产地址、账号、消费组、桶名或
运行数据。大屏和告警属于金龄云 SaaS 日志系统，生产导入时放入对应业务组。

## 快速入口

- [快速开始](#快速开始)
- [生产日志检索大屏配置与导入指南](docs/grafana-victorialogs-log-search-dashboard-guide.md)
- [查询性能与升级运行手册](docs/grafana-victorialogs-query-performance-runbook.md)
- [Vector/VictoriaLogs 延迟排查运行手册](docs/vector-victorialogs-latency-runbook.md)
- [AI Agent 配置、升级与验收指南](docs/ai-agent-operations-guide.md)
- [VictoriaLogs MCP 部署说明](docker-compose/mcp-victorialogs/README.md)
- [AutoMQ + 对象存储日志缓冲层](docker-compose/automq/README.md)
- [日志链路选型与 Kubernetes 快速启用指南](docs/log-pipeline-selection.md)

## VVG 核心架构

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

## 核心特性

- **🚀 高性能**: VictoriaLogs 提供极高的写入和查询性能
- **📦 轻量级**: 相比 ELK 栈，资源占用更少
- **🔧 易部署**: Docker Compose 一键部署，vector支持kubernetes分布式部署
- **📊 可视化**: Grafana 提供强大的日志查询和可视化功能
- **🔍 智能解析**: 自动识别 Nginx 和 Java 日志格式
- **🔄 可靠传输**: 持久磁盘缓冲、背压和可回滚升级，后端短时维护不主动丢新日志
- **🧩 多条件检索**: message 包含/不包含、全局 AND/OR、显式 Apply/Reset、URL 状态恢复
- **📈 清晰趋势**: 复用 Explore Logs volume 的连续时间桶，宽时间范围仍保持可读柱形
- **⚡ 查询保护**: 默认 15 分钟、All 展开为 `*`、明细 500 行、输入期间零查询
- **🔒 可审计插件**: 精确版本、SHA-256、不可变 release、只读挂载和原子回滚

## 界面预览

生产与测试共享同一 Dashboard 逻辑。以下截图来自脱敏演示环境，实时计数仅用于展示布局。

![VVG 日志检索大屏总览](docs/images/vvg-dashboard-overview.png)

多条件 message 过滤器支持逐行添加、包含/不包含和全局 AND/OR。编辑期间不查询；点击“应用过滤”会在一次状态更新中同时应用条件并重算相对时间，只查询一轮四个面板即可得到最新日志。

![VVG message 多条件过滤器](docs/images/vvg-message-filter-builder.png)

## 支持的日志格式

### Nginx 日志
- **Access Log**: 标准格式和 JSON 格式
- **Error Log**: 标准错误日志格式
- **自定义格式**: 支持自定义 log_format

### Java 应用日志
- **单行日志**: 标准 Java 应用日志
- **多行日志**: 异常堆栈、调试信息自动合并 ⭐
- **智能识别**: 支持时间戳和日志级别开头格式
- **双层处理**: 容器运行时层 + 应用层多行处理 ⭐
- **JSON 格式**: 结构化 Java 日志

## 快速开始

本系统支持多种部署方式，可根据实际环境选择合适的部署架构。

### 部署架构选择

**选项 1: 单机部署**
- 所有组件部署在同一台服务器
- 适合测试环境或小规模应用

**选项 2: 分布式部署** (推荐)
- VictoriaLogs: 部署在存储服务器
- Grafana: 部署在展示服务器  
- Vector: 部署在各个应用服务器

**选项 3: Kubernetes 部署** ⭐ 推荐
- 适合容器化环境和微服务架构
- 支持 Docker CRI 和 Containerd CRI
- **Java多行日志增强**: 异常堆栈自动合并 ⭐
- **双层多行处理**: 容器分割 + 应用层处理
- **持久可靠缓冲**: 每节点 1GiB 磁盘缓冲，后端短时维护不主动丢新日志
- **低延迟采集**: 5秒文件发现、活跃文件公平读取、1秒批次

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
# 编辑 .env，设置 VictoriaLogs 地址、管理员密码、数据目录和固定镜像
sudo bash ../../scripts/install-grafana-plugins.sh .env
sudo mkdir -p /data/grafana/grafana-data
sudo chown 472:472 /data/grafana/grafana-data
docker compose --env-file .env up -d
```

详细说明: [Grafana 部署文档](docker-compose/grafana/README.md)

#### 3. 部署 VictoriaLogs MCP（可选）

MCP 使用独立 Compose 项目，不重建 Grafana、VictoriaLogs 或 Vector。测试和生产分别部署，临时内网入口为 `http://HOST:8081/mcp`，并强制 Bearer Token。

```bash
cd docker-compose/mcp-victorialogs
cp env.example .env
# 将官方固定镜像镜像到私库，渲染独立 Token 和 vmauth/auth.yml
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d
```

详细说明：[VictoriaLogs MCP 部署文档](docker-compose/mcp-victorialogs/README.md)

#### 4. 部署 Vector (日志收集)

在每台需要收集日志的应用服务器上:

```bash
cd docker-compose/vector
cp env.example .env
# 编辑 .env 文件，设置 VictoriaLogs 服务器地址和日志路径
sudo mkdir -p /data/vector-docker/vector_data
docker-compose up -d
```

详细说明: [Vector 部署文档](docker-compose/vector/README.md)

#### 5. Kubernetes 部署 (可选) ⭐

在 Kubernetes 环境中部署 Vector 进行日志收集:

```bash
# 1. 选择日志和链路，再修改示例地址与私库镜像
cd k8s-deployment

# 2. 根据容器运行时选择配置文件
# Docker CRI
kubectl apply -f vector/vvg/direct-docker.yaml

# Containerd CRI  
kubectl apply -f vector/vvg/direct-containerd.yaml

# 3. 验证部署
kubectl get pods -n logging
```

详细说明: [Kubernetes 部署文档](k8s-deployment/README.md)

VVG/Gateway 的 direct 与 AutoMQ 四条完整路线见
[日志链路选型与 Kubernetes 快速启用指南](docs/log-pipeline-selection.md)。

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
# Docker Compose 默认只绑定宿主机 loopback
curl http://127.0.0.1:8686/health

# Kubernetes 部署
kubectl get pods -n logging
kubectl logs -n logging -l app=vector --tail=50
```

### 配置校验

提交或部署前运行：

```bash
# 不需要 Docker，检查固定版本、危险默认值、凭据和关键基线
bash scripts/validate-configs.sh --static

# 需要 Docker；展开三套 Compose、构建并校验外置 Grafana 插件包，
# 并用 Vector 0.58 实际校验 Docker 与两套 K8S 配置
bash scripts/validate-configs.sh --runtime
```

Pull Request 和 `main` 分支会通过 GitHub Actions 重复执行完整校验。`.env`、`服务器信息.txt` 和运行数据目录不得提交到仓库。

已有 Grafana 迁移、隔离验证、Chrome 验收和回滚流程见 [VVG AI Agent 配置、升级与验收指南](docs/ai-agent-operations-guide.md)。

## 项目结构

```
├── docker-compose/
│   ├── victorialogs/               # VictoriaLogs 存储
│   ├── clickhouse/                  # ClickHouse 服务、TTL 和 Gateway schema
│   ├── grafana/
│   │   ├── dashboards/             # 生产 Dashboard JSON
│   │   ├── datasources/            # datasource provisioning
│   │   ├── routes/                  # 可选 Gateway ClickHouse 配置
│   │   ├── panel-templates/        # 生成的 Business Text 面板模板
│   │   ├── docker-compose.yml
│   │   ├── env.example
│   │   └── README.md
│   ├── mcp-victorialogs/           # 官方 MCP + vmauth 查询保护
│   ├── automq/                      # AutoMQ + OBS 持久缓冲、消费者与监控
│   └── vector/                     # Docker Vector
├── k8s-deployment/
│   └── vector/
│       ├── vvg/                    # VVG direct / AutoMQ 完整清单
│       └── gateway/                # Gateway direct / AutoMQ 完整清单
├── scripts/
│   ├── install-grafana-plugins.sh  # 原子发布外置插件 release
│   ├── render-automq-example-manifests.py
│   ├── render-vvg-message-filter.mjs
│   ├── validate-vvg-message-filter.mjs
│   └── validate-configs.sh
├── docs/
│   ├── images/                     # 脱敏界面截图
│   ├── log-pipeline-selection.md   # 四条日志链路选型和快速启用入口
│   └── ai-agent-operations-guide.md
├── AGENTS.md                       # AI Agent 全仓库约束
├── .github/workflows/              # PR/main 自动校验
├── LICENSE
└── README.md
```

## 配置说明

### 环境变量配置

每个服务的配置文件都位于对应目录下的 `env.example`，使用前需要复制为 `.env` 并修改相关参数:

- **VictoriaLogs**: 端口、数据保留期、存储路径
- **Grafana**: VictoriaLogs 地址、管理员密码、端口  
- **Vector (Docker Compose)**: VictoriaLogs 地址、日志文件路径、主机标识
- **Vector (Kubernetes)**: VictoriaLogs 地址、Java 多行日志增强处理、高性能缓冲配置

### 网络配置

各服务默认使用 `vvg-monitoring` 网络。分布式部署时，确保:
- VictoriaLogs 的 9428 端口可被 Grafana 和 Vector 访问
- Grafana 的 3000 端口可被用户访问
- Kubernetes 环境中 Vector 能访问 VictoriaLogs 服务
- 配置正确的防火墙规则

## 自定义配置

### 日志格式定制

编辑相应的配置文件可以:

**Docker Compose 部署**:
- 编辑 `docker-compose/vector/vector.yaml`

**Kubernetes 部署**:
- 编辑 `k8s-deployment/vector/<日志类型>/` 中对应 direct源清单，再重新生成 AutoMQ清单

支持的自定义内容:
- 添加新的日志源
- 修改日志解析规则  
- 自定义数据处理逻辑
- 配置日志过滤条件
- Java 多行日志匹配规则

### 性能调优

根据数据量调整:
- **VictoriaLogs**: 内存限制和查询参数
  - 默认查询并发 4；仅在触顶/超时指标增长且资源有余量时提高
- **Vector**: 批处理大小和缓冲区配置
  - Docker file source：1秒发现 + 64KiB公平读取 + 10GiB磁盘缓冲
  - Kubernetes 版本：1MB/500事件批次 + 1秒超时 + 1GiB磁盘缓冲
  - 显式排除 `.gz/.tmp`，避免快速轮转文件晚读后批量涌入
  - 保留真实事件时间，不使用 `rewrite_timestamp` 掩盖积压
- **Grafana**: Explore 默认15分钟、最多500行、60秒数据源超时

## VVG 主系统文档

使用与排障：

- [生产日志检索大屏配置与导入指南](docs/grafana-victorialogs-log-search-dashboard-guide.md)
- [Grafana/VictoriaLogs 查询性能与升级运行手册](docs/grafana-victorialogs-query-performance-runbook.md)
- [Vector/VictoriaLogs 延迟排查与升级运行手册](docs/vector-victorialogs-latency-runbook.md)
- [故障排查指南](docs/troubleshooting.md)
- [AI Agent 配置、升级与验收指南](docs/ai-agent-operations-guide.md)

部署说明：

- [VictoriaLogs 部署说明](docker-compose/victorialogs/README.md)
- [Grafana 部署说明](docker-compose/grafana/README.md)
- [VictoriaLogs MCP 部署说明](docker-compose/mcp-victorialogs/README.md)
- [AutoMQ + OBS 日志缓冲层运行手册](docs/automq-log-buffer-runbook.md)
- [架构决策 ADR-002：AutoMQ 对象存储日志缓冲层](docs/decisions/0002-automq-object-storage-log-buffer.md)
- [Vector 部署说明](docker-compose/vector/README.md)
- [Kubernetes 部署说明](k8s-deployment/README.md)

字段模板参考：

- [研发现场日志查询与过滤参考](docs/grafana-victorialogs-研发现场日志查询%20&%20过滤手册.md)：包含可选结构化字段示例，使用前应按当前日志字段核对。

## 附加方案：Gateway 结构化日志分析

Gateway访问日志仍是独立的数据链路，但部署文件按服务归位：ClickHouse位于
`docker-compose/clickhouse/`，Kubernetes Vector位于
`k8s-deployment/vector/gateway/`，Grafana可选配置位于
`docker-compose/grafana/routes/gateway-clickhouse/`。当前基线为 ClickHouse
`26.8.2.7-alpine` 和 Grafana ClickHouse datasource `4.5.1`。

该模板不会携带现场地址或凭据，并通过 CI 阻止有限重试、无界 system log、非持久 buffer、`latest`、华为云下载链接和真实环境标识回流仓库。

```text
Gateway stdout -> Vector 0.58 -> ClickHouse 26.8 LTS -> Grafana
                     |               |
                     |               +-- 月分区 / 紧凑主键 / 30 天业务 TTL
                     +-- checkpoint / 1 GiB disk buffer / 180 秒可靠重试 / GeoIP
```

附加方案文档：

- [ClickHouse 服务部署](docker-compose/clickhouse/README.md)
- [Gateway Vector direct / AutoMQ 配置](k8s-deployment/vector/gateway/README.md)
- [Grafana Gateway ClickHouse 可选路线](docker-compose/grafana/routes/gateway-clickhouse/README.md)
- [生产盘点、升级、隔离验证和回滚手册](docs/vector-clickhouse-gateway-runbook.md)
- [架构决策 ADR-001](docs/decisions/0001-vector-clickhouse-gateway.md)
- [仓库结构 ADR-003](docs/decisions/0003-service-oriented-log-deployment-layout.md)

以下截图来自生产案例的脱敏只读视图，域名、项目名和地址均已替换为示例值：

![Gateway ClickHouse 日志分析大屏](docs/images/clickhouse-gateway-overview.png)

## 贡献

欢迎提交 Issue 和 Pull Request！

## 许可证

本项目采用 [MIT 许可证](LICENSE)。

## 相关链接

- [VictoriaLogs 官方文档](https://docs.victoriametrics.com/VictoriaLogs/)
- [Vector 官方文档](https://vector.dev/docs/)
- [Grafana 官方文档](https://grafana.com/docs/)

---

**注意**: 生产环境部署前请仔细阅读各服务的部署文档，确保正确配置安全和性能参数。 
