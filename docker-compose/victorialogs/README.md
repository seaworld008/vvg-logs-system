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

对于高负载环境，可以在 `docker-compose.yml` 中添加性能参数：

```yaml
command:
  - '--storageDataPath=/victoria-logs-data'
  - '--httpListenAddr=:9428'
  - '--retentionPeriod=180d'
  - '--memory.allowedPercent=80'        # 允许使用更多内存
  - '--search.maxQueryDuration=60s'     # 最大查询时间
  - '--search.maxConcurrentRequests=16' # 并发查询数
```

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
