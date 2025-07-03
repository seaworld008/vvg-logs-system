# Grafana 日志可视化服务部署

Grafana 提供日志查询和可视化界面。

## 快速部署

1. **复制配置文件**
```bash
cp env.example .env
```

2. **修改配置**
编辑 `.env` 文件，主要修改：
- `VICTORIALOGS_HOST`: VictoriaLogs 服务器 IP 地址
- `GRAFANA_ADMIN_PASSWORD`: 管理员密码（重要！）
- `GRAFANA_PORT`: Grafana 服务端口

3. **创建数据目录**
```bash
sudo mkdir -p /data/grafana/grafana-data
sudo chown 472:472 /data/grafana/grafana-data
sudo chmod 755 /data/grafana/grafana-data
```

4. **启动服务**
```bash
docker-compose up -d
```

5. **访问界面**
```bash
# 访问 Grafana
http://localhost:3000
# 用户名: admin
# 密码: 你在 .env 文件中设置的密码
```

## 配置说明

### 环境变量

- `VICTORIALOGS_HOST`: VictoriaLogs 服务器地址
- `GRAFANA_ADMIN_USER`: 管理员用户名
- `GRAFANA_ADMIN_PASSWORD`: 管理员密码
- `GRAFANA_DATA_DIR`: Grafana 数据存储目录

### 数据源配置

数据源配置文件位于 `datasources/victorialogs.yaml`，启动时会自动配置 VictoriaLogs 数据源。

如需修改数据源地址，编辑该文件中的 `url` 字段：
```yaml
url: http://YOUR_VICTORIALOGS_IP:9428
```

### 插件说明

已预装插件：
- `victoriametrics-logs-datasource`: VictoriaLogs 数据源插件
- `grafana-piechart-panel`: 饼图面板
- `grafana-worldmap-panel`: 世界地图面板

## 使用指南

### 日志查询

1. 点击左侧菜单 "Explore"
2. 选择 "VictoriaLogs" 数据源
3. 使用查询语法：
   - 查看所有日志: `*`
   - 按服务筛选: `{job="nginx"}`
   - 按日志类型: `{log_type="access"}`
   - 错误日志: `{job="nginx"} |= "error"`

### 仪表板

可以创建自定义仪表板来监控：
- 请求量统计
- 错误率趋势
- 响应时间分布
- 访问来源分析

## 安全配置

### 生产环境建议

1. **修改默认密码**
```bash
# 在 .env 文件中设置强密码
GRAFANA_ADMIN_PASSWORD=your_strong_password
```

2. **禁用用户注册**
```bash
GRAFANA_ALLOW_SIGN_UP=false
```

3. **启用 HTTPS**
在 docker-compose.yml 中添加 SSL 配置或使用反向代理。

## 故障排查

### 常见问题

1. **启动失败**
```bash
# 检查数据目录权限
ls -la /data/grafana/
sudo chown 472:472 /data/grafana/grafana-data
```

2. **无法连接数据源**
```bash
# 测试网络连通性
curl -I http://VICTORIALOGS_HOST:9428/health

# 检查数据源配置
cat datasources/victorialogs.yaml
```

3. **插件问题**
```bash
# 查看插件安装日志
docker-compose logs grafana | grep plugin

# 手动安装插件
docker exec -it grafana grafana-cli plugins install victoriametrics-logs-datasource
``` 