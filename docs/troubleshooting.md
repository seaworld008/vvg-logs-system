# VVG 日志收集系统 - 故障排查

本文档提供 VVG 日志收集系统的通用故障排查方法。具体服务的详细故障排查请参考各服务目录下的 README.md 文件。

日志出现“长时间没有、随后批量涌入”时，不要先调大 VictoriaLogs 或日志轮转文件。请直接使用 [Vector -> VictoriaLogs 延迟、批量涌入与升级运行手册](vector-victorialogs-latency-runbook.md)，按源文件、Vector、VictoriaLogs、Grafana 四层定位。

Grafana 查询按钮转圈、账号间体验不一致或升级插件时，请使用 [Grafana/VictoriaLogs 查询性能与升级运行手册](grafana-victorialogs-query-performance-runbook.md)，先区分浏览器取消、查询语法、插件和后端执行时间。

## 🔍 快速诊断

### 系统整体检查

```bash
# 检查所有相关容器状态
docker ps | grep -E "(victorialogs|grafana|vector)"

# 检查网络连通性
docker network ls | grep vvg

# 检查端口占用
netstat -tlnp | grep -E "(3000|9428|8686)"
```

## 🔗 服务间连接测试

### VictoriaLogs 连接测试

```bash
# 从 Grafana 服务器测试到 VictoriaLogs
curl -I http://VICTORIALOGS_IP:9428/health

# 从 Vector 服务器测试到 VictoriaLogs  
curl -I http://VICTORIALOGS_IP:9428/health
```

### 端到端测试

```bash
# 1. 检查 VictoriaLogs 是否有数据
curl -X POST "http://VICTORIALOGS_IP:9428/select/logsql/query" \
  -d "query=*" \
  -d "limit=10"

# 2. 在 Grafana 中查询测试
# 访问 Grafana -> Explore -> 查询: {job="nginx"}
```

## 🚨 常见问题

### 日志断续、延迟后批量出现

先比较 VictoriaLogs `_time` 与 `_msg` 中应用日志时间：

```bash
curl -fsSG 'http://VICTORIALOGS_HOST:9428/select/logsql/query' \
  --data-urlencode 'query=container:="SERVICE_NAME"' \
  --data-urlencode 'start=START_RFC3339' \
  --data-urlencode 'end=END_RFC3339' \
  --data-urlencode 'limit=100'
```

重点检查：

- 显式 `exclude_paths_glob_patterns` 是否重新加入 `**/*.gz` 和 `**/*.tmp`。
- 快速轮转环境的 `glob_minimum_cooldown_ms` 是否仍为默认 60 秒。
- 是否使用 `oldest_first: true` 导致旧文件阻塞当前日志。
- 是否存在 `string!(.kubernetes.container_name)` 空字段错误。
- 是否使用 `rewrite_timestamp` 把旧日志改写成当前时间。
- VictoriaLogs 写入错误、写入延迟和磁盘是否真的异常。

推荐基线见 `k8s-deployment/vector/vvg/direct-containerd.yaml`。正常低频 Java 日志可能等待最多约 3 秒多行收束加 1 秒批次，不应出现分钟级积压。

### Grafana 查询按钮持续转圈

先检查 Grafana 请求日志：

```bash
docker logs --since 2h grafana 2>&1 | grep -E \
  'path=/api/ds/query|context canceled|cannot parse|timeout|status=5[0-9][0-9]'
```

- `499/context canceled` 通常表示浏览器主动取消，不是 VictoriaLogs 查询超时。
- `cannot parse query` 是 LogsQL 语法错误，提高并发无效。
- 旧 Explore URL 的 `range` 会覆盖默认 15 分钟；重新打开空白 `/explore` 验证。
- 用 VictoriaLogs `/select/logsql/query` 和 `/hits` 直接测量同一时间窗，区分前端和后端。

详细指标、基准命令和升级回滚步骤见专项运行手册。

### 容器启动失败

```bash
# 查看具体错误
docker-compose logs <service-name>

# 检查磁盘空间
df -h

# 检查内存使用
free -h
```

### 网络连接问题

```bash
# 检查防火墙状态
sudo ufw status

# 检查 Docker 网络
docker network inspect vvg-monitoring

# 测试端口连通性
telnet TARGET_IP PORT
```

### 权限问题

```bash
# VictoriaLogs 数据目录
sudo chown -R 1000:1000 /data/victorialogs/victoria-logs-data/

# Grafana 数据目录
sudo chown -R 472:472 /data/grafana/grafana-data/

# Vector 日志文件
sudo chmod +r /var/log/nginx/*.log
sudo chmod +r /var/log/java/*/*.log
```

## 📊 性能问题

### 资源使用检查

```bash
# 容器资源使用
docker stats

# 系统负载
top
iostat -x 1 5

# 磁盘使用
du -sh /data/*
```

### 常见优化

1. **增加内存限制**
```yaml
deploy:
  resources:
    limits:
      memory: 4G
```

2. **调整批处理与可靠缓冲**
```yaml
# Vector 配置
batch:
  max_bytes: 1048576
  max_events: 500
  timeout_secs: 1
buffer:
  type: disk
  max_size: 1073741824
  when_full: block
```

`memory + drop_newest` 会在 VictoriaLogs 维护或网络抖动时主动丢新日志，不适合作为生产日志的默认容错策略。

3. **按指标调整查询并发**

```bash
curl -fsS http://VICTORIALOGS_HOST:9428/metrics | grep -E \
  '^(vl_concurrent_select_capacity|vl_concurrent_select_current|vl_concurrent_select_limit_reached_total|vl_concurrent_select_limit_timeout_total|vl_slow_queries_total) '
```

默认并发为 4。只有触顶/排队超时计数持续增长且 CPU、内存仍有余量时才逐档提高；计数为 0 时先修复时间范围、返回行数、LogsQL、浏览器取消或网络问题。

## 📝 日志分析

### 查看服务日志

```bash
# VictoriaLogs
docker-compose logs -f victorialogs

# Grafana  
docker-compose logs -f grafana

# Vector
docker-compose logs -f vector
```

### 常见错误信息

- **"connection refused"**: 网络连接问题
- **"permission denied"**: 文件权限问题  
- **"no space left"**: 磁盘空间不足
- **"out of memory"**: 内存不足
- **"Failed to annotate event with pod metadata"**: Pod 已删除或元数据缓存缺失；升级到 Vector 0.58+ 并保持过滤条件空值安全
- **"VRL condition execution failed: expected string, got null"**: 对可空字段使用了 `string!`，改为 `string(...) ?? ""`

## 🆘 获取支持

详细的服务故障排查请查看：

- [VictoriaLogs 故障排查](../docker-compose/victorialogs/README.md#故障排查)
- [Grafana 故障排查](../docker-compose/grafana/README.md#故障排查)  
- [Vector 故障排查](../docker-compose/vector/README.md#故障排查)
- [Grafana/VictoriaLogs 查询性能与升级运行手册](grafana-victorialogs-query-performance-runbook.md)

如问题仍无法解决，请在 GitHub 上创建 Issue，并提供：
- 系统信息 (OS, Docker 版本)
- 错误日志
- 配置文件
- 复现步骤
