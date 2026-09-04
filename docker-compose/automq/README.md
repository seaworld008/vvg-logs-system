# AutoMQ + S3 日志缓冲层

本目录提供单节点 AutoMQ、两个独立 Vector 消费者和 vmagent 的受控
Docker Compose 部署。目标链路为：

```text
VVG Vector     -> AutoMQ -> Vector consumer -> VictoriaLogs
Gateway Vector -> AutoMQ -> Vector consumer -> ClickHouse
```

生产操作必须先阅读
[AutoMQ 日志缓冲层运行手册](../../docs/automq-log-buffer-runbook.md)。单节点模式
不是 AutoMQ 官方生产高可用架构；对象存储保存消息数据并不消除 KRaft metadata
和 Broker 的单点可用性风险。

本方案面向中大规模日志和明显的突发流量。小到中等规模环境仍优先使用仓库现有
Vector 直写 VictoriaLogs/ClickHouse 配置，以减少组件与故障面；直写配置也是本方案
的正式回滚基线，不能被 AutoMQ producer 清单覆盖或删除。

## 固定基线

- AutoMQ `1.7.4`，执行时重新解析当前稳定版并排除 `rc/alpha/beta/nightly`；
- Kafka protocol `3.9.1`；
- Vector `0.58.0-alpine`；
- vmagent `v1.147.0`；
- AutoMQ `3 CPU / 6 GiB`，官方 Tiny 内存参数（Heap 1 GiB、Direct Memory 1.5 GiB）；
- VVG Topic 12 partitions，Gateway Topic 6 partitions；
- 单条 4 MiB、Zstd、72 小时 retention、replication factor 1；
- `SASL_PLAINTEXT + SCRAM-SHA-512`，关闭自动建 Topic；
- 对外只发布 Kafka 端口，Controller、内部 Broker 和指标端口不对外发布。

## 宿主机目录

正式目录固定为 `/data/automq`。仓库文件发布到该目录后创建：

```text
/data/automq/
  config/       # 可提交模板
  monitoring/   # Dashboard 和告警源
  scripts/      # 部署脚本
  runtime/      # 渲染后包含认证的配置，0600，不入 Git
  secrets/      # OBS、SCRAM、ClickHouse 凭据，0600，不入 Git
  state/        # KRaft、Vector buffer、vmagent queue
  backups/      # 每次变更的一致性备份和 SHA256SUMS
  artifacts/    # 已验证镜像归档及 SHA-256
```

必需的人工提供文件只有：

```text
secrets/obs-access-key
secrets/obs-secret-key
secrets/clickhouse/username
secrets/clickhouse/password
```

其余 SCRAM 密码和 Cluster ID 由 `scripts/render-runtime.sh` 首次生成。脚本不会
打印秘密。`.env`、`runtime/`、`secrets/`、`state/`、`backups/` 均被 Git 忽略。

## 部署顺序

```bash
cd /data/automq
cp env.example .env
# 填写已验证镜像 digest、宿主机地址、OBS 桶和后端地址
chmod 0600 .env secrets/* secrets/*/*

bash scripts/render-runtime.sh
docker compose --env-file .env --profile shadow config --quiet
docker compose --env-file .env --profile shadow up -d
```

`automq-init` 只在空 KRaft 目录执行 format，并把 admin SCRAM 用户写入 metadata。
`automq-bootstrap` 幂等创建其余用户、ACL 和两个 Topic。正式消费者使用单独的
consumer group 与 state 目录：

```bash
docker compose --env-file .env --profile shadow stop \
  vector-vvg-shadow vector-gateway-shadow
docker compose --env-file .env --profile production up -d \
  vector-vvg-production vector-gateway-production vmagent
```

不能让 shadow 和 production 消费者同时写同一个正式后端。生产 group 首次启动
必须先于生产者主切，使用 `latest` 建立当前末尾 offset，避免把影子历史重新灌入。

### VVG consumer 跨主机放置

当 VictoriaLogs 与 AutoMQ 位于不同宿主机，且 VictoriaLogs 主机通过资源门禁后，可用
`docker-compose.vvg-consumers.yml` 将三个 VVG consumer 放到 VictoriaLogs 所在主机，
减少解压后日志的跨机传输。复制 `vvg-consumers.env.example` 为目标机本地 `.env`，填入
已验证的镜像 digest、VPC 内 Kafka 地址和 VictoriaLogs 地址；`.env` 与 SCRAM password
必须保持 `0600` 且不得进入 Git。

三个服务使用同一 production consumer group，但分别使用独立 state 目录和 metrics
端口。迁移时每次只启动一个新实例，确认 group rebalance、事件收发和错误计数后，再
优雅停止一个旧实例。Kafka offset 是恢复依据，不复制 Vector memory buffer。AutoMQ、
Gateway consumer 和 ClickHouse 应继续同机，除非另有独立迁移与回滚方案。

旧实例停止后必须禁用其自动重启策略，避免原宿主机或 Docker daemon 重启时重新加入
生产 group。验收前可保留已停止容器作为快速回滚入口；回滚时先恢复 `restart: always`
再逐实例启动。远端放置生效后，日常执行原 AutoMQ Compose 时不得再次启动本地
`vector-vvg-production` 服务。

目标机使用旧版 Compose 时先运行：

```bash
docker-compose --env-file .env -f docker-compose.yml config --quiet
docker image inspect "$(sed -n 's/^VECTOR_IMAGE=//p' .env)"
```

正式启动必须使用已存在的精确镜像，禁止为完成迁移临时在线拉取。

## Vector producer 清单

仓库已提交两份由当前公开基线生成的完整 production清单：

```text
k8s-deployment/vector/vvg/automq-containerd-production.yaml
k8s-deployment/vector/gateway/automq-containerd-production.yaml
```

新部署可按[日志链路选型与 Kubernetes 快速启用指南](../../docs/log-pipeline-selection.md)
替换占位符并创建 Secret。已有生产环境若包含自定义 selector、解析、GeoIP或字段，仍
必须从现场真实源 manifest重新生成候选，不能用公开示例覆盖。

不要手改线上嵌入式 `vector.yaml`。从真实部署源文件渲染：

```bash
python3 scripts/render-automq-vector-manifest.py \
  --pipeline vvg --mode shadow \
  --input vector-log.before.yaml --output vector-vvg-shadow.yaml \
  --vector-image registry.example.com/observability/timberio/vector:0.58.0-alpine@sha256:VERIFIED \
  --bootstrap automq.example.internal:9092
```

`gateway` 与 `production` 使用同一命令的对应参数。shadow 使用独立 DaemonSet、
ConfigMap 和 hostPath；production 保留原资源名、checkpoint 与 hostPath，只替换
发送目标。Gateway 进入 Kafka 前已经完成解析与脱敏，原始 header/body 不写入 OBS。
producer 同时保留官方 `rebootstrap`/完整 metadata 刷新和有条件 liveness：Broker
不可达时只使用 hostPath disk buffer；Broker 已恢复但发送连续 90 秒停滞时重启 Pod，
并从同一 ledger 继续排空。consumer group 的长故障恢复由宿主机 systemd watchdog
兜底，不能把仅能连接 Kafka 端口当作恢复完成。VVG 的 `kubernetes_logs` source 官方
语义仍是 best effort 且不支持 source acknowledgement；本方案的至少一次保证从事件
可靠进入 producer disk buffer 后开始，不能把它扩大为容器日志文件到存储端的绝对
端到端保证。

公开 production清单的统一生成与防漂移检查：

```bash
python3 scripts/render-automq-example-manifests.py
python3 scripts/render-automq-example-manifests.py --check
```

CCE 管理节点顶层只保留当前 production清单和校验文件；直写、shadow、候选与旧
production现场副本进入权限受限且带 SHA-256 的归档。Git仓库仍长期保留全部通用路线：

```text
efk/vector-log/
  vector-automq-production.yaml
  SHA256SUMS-automq
  archive/<timestamp>/
    vector-k8s-containerd-cri.yaml
    vector-automq-shadow.yaml
efk/vector-gateway/
  vector-automq-production.yaml
  SHA256SUMS-automq
  archive/<timestamp>/
    vector-k8s-with-new-fields.yaml
    vector-automq-shadow.yaml
```

## 验证

```bash
bash scripts/validate-automq.sh --static
bash scripts/validate-automq.sh --runtime
```

生产验收和回滚见运行手册。OBS 桶不得设置会早于 Kafka retention 删除对象的生命周期
规则；只允许应用 `config/obs-lifecycle.json`，清理七天前仍未完成的 multipart upload。
Grafana/Nightingale 大屏与告警属于金龄云 SaaS 日志系统，必须导入对应的金龄云
SaaS 业务组，并在启用前用真实 VictoriaMetrics 数据源逐条验证表达式；不得放入
通用基础设施或其他项目的业务组。
