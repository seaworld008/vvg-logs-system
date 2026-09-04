# VictoriaLogs 日志存储服务部署

VictoriaLogs 是高性能的日志存储和查询后端。

当前基线版本为 `v1.52.0`。该版本使用 distroless 镜像，容器内没有 shell、`wget` 或 `curl`；健康检查必须从宿主机、监控系统或独立探针访问 `/health`，不能使用容器内 `CMD-SHELL wget`。

## 快速部署

1. **复制配置文件**
```bash
cp env.example .env
```

2. **修改配置**
编辑 `.env` 文件，主要修改：
- `VICTORIALOGS_PORT`: 服务端口（默认9428）
- `VICTORIALOGS_RETENTION`: 日志保留期（默认180天）
- `VICTORIALOGS_DATA_DIR`: 数据存储路径

3. **创建数据目录**
```bash
sudo mkdir -p /data/victorialogs/victoria-logs-data
sudo chmod 755 /data/victorialogs/victoria-logs-data
```

4. **启动服务**
```bash
docker-compose up -d
```

5. **验证部署**
```bash
# 检查服务状态
curl -fsS http://localhost:9428/health
curl -fsS http://localhost:9428/metrics

# 查看容器日志
docker-compose logs -f victorialogs
```

## 配置说明

### 环境变量

- `VICTORIALOGS_PORT`: HTTP 监听端口
- `VICTORIALOGS_RETENTION`: 数据保留期（如：180d, 30d, 1y）
- `VICTORIALOGS_DATA_DIR`: 数据存储目录
- `TIMEZONE`: 时区设置
- `DOCKER_REGISTRY`: 官方默认为 `docker.io`；生产环境应改为已经验证的私有镜像前缀
- `VICTORIALOGS_VERSION`: 固定版本 tag，不要使用 `latest`

### 优雅停止

Compose 已配置：

```yaml
stop_signal: SIGINT
stop_grace_period: 2m
```

VictoriaLogs 升级或重建前需要优雅停止并等待存储刷盘。不要直接强制删除运行中的容器。

### 性能调优

Compose 默认使用已验证的查询控制基线：

```dotenv
VICTORIALOGS_CPUS=3.0
VICTORIALOGS_MEMORY_LIMIT=5g
VL_SEARCH_MAX_CONCURRENT_REQUESTS=4
VL_SEARCH_MAX_QUEUE_DURATION=1m
VL_DEFAULT_PARALLEL_READERS=1
VL_SEARCH_MAX_QUERY_DURATION=2m
VL_SEARCH_SLOW_QUERY_DURATION=8s
```

该参考规格来自 4 核主机上的单节点部署。查询并发 4 已覆盖 Grafana 同时发出的日志列表和日志量请求；并发上限并不是越大越快，超过 CPU 能力会增加上下文切换和尾延迟。

先观察以下指标：

```bash
curl -fsS http://127.0.0.1:9428/metrics | grep -E \
  '^(vl_concurrent_select_capacity|vl_concurrent_select_current|vl_concurrent_select_limit_reached_total|vl_concurrent_select_limit_timeout_total|vl_slow_queries_total) '
```

只有同时满足以下条件时才逐步提高 `VL_SEARCH_MAX_CONCURRENT_REQUESTS`：

1. `limit_reached_total` 或 `limit_timeout_total` 在业务查询期间持续增长。
2. 容器 CPU 没有长期接近上限，内存和磁盘仍有明确余量。
3. 缩小 Grafana 默认时间范围、限制返回行数和优化 LogsQL 后仍存在排队。

每次只增加一个小档位并复测 P95/P99。若触顶计数为 0，提高并发不会解决浏览器取消、错误查询语法或网络问题。

## 运行监控

VictoriaLogs 在 `/metrics` 暴露官方 Prometheus 指标。生产 vmagent 应使用独立
`victorialogs` job抓取该端点，再 remote write到夜莺使用的 VictoriaMetrics数据源。

仓库提供两份固定版本的大屏：

- `monitoring/grafana/victorialogs-v1.52.0.json`：VictoriaLogs `v1.52.0` 官方原始文件，
  保留官方 SHA-256；
- `monitoring/nightingale/victorialogs-v1.52.0.json`：夜莺 v9.1.1 原生版本，保留全部
  73 个面板，并把唯一不支持的 Grafana table转换为 `barGauge`。

来源、校验和、导入方式和升级边界见 [监控资产说明](monitoring/README.md)。

## API 使用

### 数据写入

Vector 会自动通过 Loki API 写入数据：
```
POST http://localhost:9428/insert/loki/api/v1/push
```

## 安全升级

完整步骤见 [Vector -> VictoriaLogs 延迟、批量涌入与升级运行手册](../../docs/vector-victorialogs-latency-runbook.md)。核心门禁如下：

1. 先把精确版本镜像到私有仓库并验证版本。
2. 备份 Compose、`docker inspect` 和升级前 metrics。
3. 为当前日期分区创建临时 snapshot。
4. `docker-compose config` 通过后，使用 `SIGINT` 优雅停止并重建单个 `victorialogs` 服务。
5. 验证 `/health=200`、写入计数增加、错误为零、历史日志可查询。
6. 验证成功后删除临时 snapshot，避免长期占用磁盘。

单节点 VictoriaLogs 可以按官方更新说明跳过多个版本升级；集群版从 `v1.38.0` 至 `v1.50.0` 升到 `v1.52.0` 时不能套用本段，必须先按官方要求处理 `v1.51.1` 中间步骤。

### 数据查询

```bash
# 查询最近的日志
curl -X POST "http://localhost:9428/select/logsql/query" \
  -d "query=*" \
  -d "limit=100"

# 按标签过滤
curl -X POST "http://localhost:9428/select/logsql/query" \
  -d "query={job=\"nginx\"}" \
  -d "limit=100"
```

## 故障排查

### 常见问题

1. **启动失败**
```bash
# 检查数据目录权限
ls -la /data/victorialogs/
sudo chown -R 1000:1000 /data/victorialogs/victoria-logs-data/
```

2. **磁盘空间**
```bash
# 监控磁盘使用
df -h /data/victorialogs/victoria-logs-data/
```

3. **查看服务状态**
```bash
# 健康检查
curl -fsS http://localhost:9428/health

# 查看容器资源使用
docker stats victorialogs
```
