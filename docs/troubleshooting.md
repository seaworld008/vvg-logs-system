# VVG 日志收集系统 - 故障排查

本文档提供 VVG 日志收集系统的通用故障排查方法。具体服务的详细故障排查请参考各服务目录下的 README.md 文件。

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

2. **调整批处理大小**
```yaml
# Vector 配置
batch:
  max_bytes: 2097152
  timeout_secs: 5
```

3. **优化查询性能**
```yaml
# VictoriaLogs 配置
command:
  - '--memory.allowedPercent=80'
  - '--search.maxConcurrentRequests=16'
```

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

## 🆘 获取支持

详细的服务故障排查请查看：

- [VictoriaLogs 故障排查](../docker-compose/victorialogs/README.md#故障排查)
- [Grafana 故障排查](../docker-compose/grafana/README.md#故障排查)  
- [Vector 故障排查](../docker-compose/vector/README.md#故障排查)

如问题仍无法解决，请在 GitHub 上创建 Issue，并提供：
- 系统信息 (OS, Docker 版本)
- 错误日志
- 配置文件
- 复现步骤 