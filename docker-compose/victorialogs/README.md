# VictoriaLogs 日志存储服务部署

VictoriaLogs 是高性能的日志存储和查询后端。

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
curl http://localhost:9428/metrics

# 查看容器日志
docker-compose logs -f victorialogs
```

## 配置说明

### 环境变量

- `VICTORIALOGS_PORT`: HTTP 监听端口
- `VICTORIALOGS_RETENTION`: 数据保留期（如：180d, 30d, 1y）
- `VICTORIALOGS_DATA_DIR`: 数据存储目录
- `TIMEZONE`: 时区设置

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
curl http://localhost:9428/metrics

# 查看容器资源使用
docker stats victorialogs
``` 