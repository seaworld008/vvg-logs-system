# Vector 日志收集器部署

Vector 负责收集应用服务器上的日志文件并发送到 VictoriaLogs。

## 快速部署

1. **复制配置文件**
```bash
cp env.example .env
```

2. **修改配置**
编辑 `.env` 文件，主要修改：
- `VICTORIALOGS_HOST`: VictoriaLogs 服务器 IP 地址
- `NGINX_LOG_PATH`: Nginx 日志目录路径
- `JAVA_LOG_PATH`: Java 应用日志目录路径
- `VECTOR_HOSTNAME`: 当前服务器标识

3. **创建数据目录**
```bash
sudo mkdir -p /data/vector-docker/vector_data
sudo chmod 755 /data/vector-docker/vector_data
```

4. **启动服务**
```bash
docker-compose up -d
```

5. **查看状态**
```bash
docker-compose ps
docker-compose logs -f vector
```

## 配置说明

### 环境变量

- `VLS_ENDPOINT`: VictoriaLogs 服务地址
- `NGINX_LOG_PATH`: Nginx 日志文件路径
- `JAVA_LOG_PATH`: Java 应用日志文件路径
- `VECTOR_DATA_DIR`: Vector 数据存储路径

### 日志格式支持

- **Nginx Access Log**: 支持标准格式和 JSON 格式
- **Nginx Error Log**: 标准错误日志格式  
- **Java 多行日志**: 支持异常堆栈等多行日志

### 自定义配置

如需修改日志处理逻辑，请编辑 `vector.yaml` 文件。

## 故障排查

### 常见问题

1. **日志文件权限问题**
```bash
# 确保 Vector 容器可以读取日志文件
sudo chmod +r /var/log/nginx/*.log
sudo chmod +r /var/log/java/*/*.log
```

2. **网络连接问题**
```bash
# 测试到 VictoriaLogs 的连接
curl -I http://VICTORIALOGS_HOST:9428/health
```

3. **查看 Vector 状态**
```bash
# Vector API 健康检查
curl http://localhost:8686/health

# 查看 Vector 日志
docker-compose logs vector
``` 