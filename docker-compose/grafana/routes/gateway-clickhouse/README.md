# Grafana Gateway ClickHouse 可选路线

本目录是唯一 Grafana服务中的可选 Gateway配置，不是第二套 Grafana部署。默认
`docker-compose/grafana/docker-compose.yml` 只启用 VVG；需要 Gateway Dashboard时叠加
本目录的 Compose override。

## 文件

```text
routes/gateway-clickhouse/
  compose.override.example.yml
  dashboard-provider.yaml
  dashboards/gateway-observability.json
  datasources/clickhouse.yaml
```

固定契约：Dashboard UID `vvg-clickhouse-gateway`、datasource UID
`gateway-clickhouse`、插件 `grafana-clickhouse-datasource 4.5.1`、最近 15 分钟、自动
刷新关闭、明细最多 500 行。

## 准备插件 release

复制 `.env` 后设置一个新的版本化插件目录，并启用精确额外插件：

```dotenv
GRAFANA_PLUGINS_DIR=/data/grafana/plugins/releases/grafana13.2.0-vl0.31.0-text6.3.0-clickhouse4.5.1
GRAFANA_EXTRA_PLUGINS=grafana-clickhouse-datasource@4.5.1
CLICKHOUSE_GRAFANA_PASSWORD=REPLACE_WITH_READ_ONLY_PASSWORD
```

在受控机器运行统一插件发布脚本；生产 Grafana仍只读挂载完成校验的 release，启动时
不联网：

```bash
cd docker-compose/grafana
sudo bash ../../scripts/install-grafana-plugins.sh .env
```

## 启用

先替换 datasource中的 ClickHouse内网地址和只读用户名，再展开组合配置：

```bash
cd docker-compose/grafana
docker compose --env-file .env \
  -f docker-compose.yml \
  -f routes/gateway-clickhouse/compose.override.example.yml \
  config --quiet
```

对已有 Grafana，先按运行手册备份 SQLite、插件清单、datasource和 Dashboard，并在数据
副本与 loopback端口隔离验证。正式更新只重建 Grafana，不重建 ClickHouse、
VictoriaLogs或 Vector。

## 验证

```bash
node scripts/validate-clickhouse-gateway.mjs
bash scripts/validate-clickhouse-gateway.sh --static
```

导入生产 API导出前先运行 sanitizer；真实地址、密码、Token和业务日志不得进入仓库或
截图。
