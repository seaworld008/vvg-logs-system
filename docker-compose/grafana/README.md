# Grafana 日志查询服务部署

当前验证基线：Grafana `13.2.0-ubuntu`、VictoriaLogs 数据源插件 `0.31.0`。

本目录使用自定义镜像在构建阶段安装插件。生产容器启动时不会联网安装或更新插件，避免插件下载卡住后 Grafana 无法监听。

预装插件位于 `/var/lib/grafana-plugins`，并通过 `GF_PATHS_PLUGINS` 显式启用。不要把插件烘焙到 `/var/lib/grafana/plugins`：Compose 会把持久化目录 bind mount 到 `/var/lib/grafana`，从而遮住镜像中该路径的内容。

## 1. 构建插件镜像

在可访问 Grafana 插件仓库的受控机器执行：

```bash
cd docker-compose/grafana

docker build \
  --build-arg GRAFANA_VERSION=13.2.0-ubuntu \
  --build-arg VICTORIALOGS_PLUGIN_VERSION=0.31.0 \
  -t vvg-grafana:13.2.0-plugin0.31.0 .

docker run --rm --entrypoint grafana \
  vvg-grafana:13.2.0-plugin0.31.0 server -v

docker run --rm --entrypoint grafana \
  vvg-grafana:13.2.0-plugin0.31.0 \
  cli --pluginsDir /var/lib/grafana-plugins plugins ls
```

生产使用私有仓库时，在维护窗口前完成 `tag`、`push`、`pull` 和镜像摘要核对，再把 `.env` 的 `GRAFANA_IMAGE` 改为私有镜像完整名称。不要使用 `latest`。

## 2. 配置和启动

```bash
cp env.example .env
```

至少修改：

- `VICTORIALOGS_URL`：Grafana 主机可访问的 VictoriaLogs 地址。
- `GRAFANA_ADMIN_PASSWORD`：生产强密码，不能保留示例占位符。
- `GRAFANA_IMAGE`：已提前构建并验证的插件镜像。
- `GRAFANA_PORT`：对外监听端口。

创建持久目录并启动：

```bash
sudo install -d -o 472 -g 472 -m 0755 /data/grafana/grafana-data
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d
curl -fsS http://127.0.0.1:3000/api/health
```

## 3. 查询体验基线

- Explore 新页面默认查询最近 15 分钟。
- 用户可通过时间选择器查询其他范围。
- 旧书签或旧标签页 URL 中的 `range` 会覆盖全局默认值，应重新打开空白 Explore 页面验证。
- 单次默认最多返回 2000 行，数据源请求超时为 60 秒。
- provisioning 数据源固定 UID `victorialogs-ds` 且不可在 UI 中修改，避免账号之间配置漂移。

查询转圈不等于后端并发不足。先检查浏览器请求、Grafana 日志和 VictoriaLogs 指标，详细流程见 [Grafana/VictoriaLogs 查询性能与升级运行手册](../../docs/grafana-victorialogs-query-performance-runbook.md)。

## 4. 安全升级

Grafana 13 会迁移 SQLite 和统一存储。升级前必须使用数据副本演练，正式切换时必须获得一致的 SQLite 备份。

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/data/grafana/backups/grafana-${STAMP}"
install -d -m 0700 "${BACKUP}"

docker compose --env-file .env stop -t 60 grafana
cp -a docker-compose.yml .env datasources dashboards grafana-data "${BACKUP}/"
docker compose --env-file .env up -d --no-deps --force-recreate grafana
```

恢复后验证：

```bash
docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' grafana
docker exec grafana grafana cli plugins ls
curl -fsS http://127.0.0.1:3000/api/health
docker logs --since 10m grafana 2>&1 \
  | grep -E 'level=error|panic|migration failed|signature.*invalid' || true
```

回滚到 Grafana 12 时不能只切旧镜像。必须停止新容器，同时恢复升级前 Compose、插件目录和 `grafana.db`，否则旧版本可能读取迁移后的不兼容状态。

## 5. 常见问题

### 插件下载卡住

不要在生产启动配置中临时加入在线插件安装变量。在有代理的工作机重新构建镜像，验证插件版本和镜像摘要，再推送到私有仓库。

### 数据源不可用

从 Grafana 主机验证：

```bash
curl -fsS "${VICTORIALOGS_URL}/health"
curl -fsS "${VICTORIALOGS_URL}/metrics" | head
```

跨主机部署不能把数据源写成 `localhost`；只有 VictoriaLogs 与 Grafana 位于同一 Docker 网络时才可使用容器名。
