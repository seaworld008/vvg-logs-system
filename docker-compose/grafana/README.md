# Grafana 日志查询服务部署

当前验证基线：Grafana `13.2.0-ubuntu`、VictoriaLogs 数据源插件 `0.31.0`、Business Text 插件 `6.3.0`。

Grafana 镜像和插件采用两个独立的固定版本。插件先发布到宿主机版本目录，再以只读方式挂载；生产容器启动时不会联网安装或更新插件，避免插件下载卡住后 Grafana 无法监听。

外置插件挂载到 `/var/lib/grafana-plugins`，并通过 `GF_PATHS_PLUGINS` 显式启用。Compose 同时设置 `GF_PLUGINS_PREINSTALL_DISABLED=true` 和 `GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`，避免 Grafana 13 后台向只读目录安装或更新建议插件。不要安装到 `/var/lib/grafana/plugins`：插件生命周期会重新与 SQLite 数据目录耦合。

## 1. 发布插件包

在可访问 Grafana 插件仓库的受控机器执行：

```bash
cd docker-compose/grafana
cp env.example .env
# 先修改 .env 中的正式参数
sudo bash ../../scripts/install-grafana-plugins.sh .env
```

安装器使用固定 Grafana 镜像的 CLI，把插件写入同一父目录下的随机暂存目录；版本、SHA-256 和只读权限通过后才原子改名为 `GRAFANA_PLUGINS_DIR`。已存在的版本目录只校验、不覆盖。

生产服务器不能访问插件站点时，在可联网的同架构 Linux 主机生成插件包，归档整个 release 目录并生成外层 SHA-256，传到生产后解压到相同绝对路径。不要在 Grafana 启动环境中加入在线安装变量。

已有 Grafana 可能在 SQLite 中保留历史应用预加载状态。切换精简 release 前必须用复制数据库隔离启动，并检查 Chrome 控制台。若出现 `Failed to preload plugin`，创建一个新的兼容 release，保留当前签名插件并只升级不兼容的精确插件版本；不要修改已发布目录。完整步骤见 [AI Agent 配置与验收指南](../../docs/ai-agent-operations-guide.md)。

## 2. 配置和启动

```bash
cp env.example .env
```

至少修改：

- `VICTORIALOGS_URL`：Grafana 主机可访问的 VictoriaLogs 地址。
- `GRAFANA_ADMIN_PASSWORD`：生产强密码，不能保留示例占位符。
- `GRAFANA_IMAGE`：固定的官方 Grafana 镜像或组织内已验证的等价镜像，禁止 `latest`。
- `GRAFANA_PLUGINS_DIR`：包含 Grafana、VictoriaLogs 和 Business Text 版本号的只读 release 目录。
- `GRAFANA_PORT`：对外监听端口。
- `GRAFANA_CPU_LIMIT`、`GRAFANA_MEMORY_LIMIT`、`GRAFANA_PIDS_LIMIT`：限制单个 Grafana 故障拖垮同机监控服务。4 核、15 GiB 的共享主机基线为 `2.0`、`4g`、`512`。

创建持久目录并启动：

```bash
sudo install -d -o 472 -g 472 -m 0755 /data/grafana/grafana-data
sudo bash ../../scripts/install-grafana-plugins.sh .env
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d
curl -fsS http://127.0.0.1:3000/api/health
```

## 3. 查询体验基线

- Explore 新页面默认查询最近 15 分钟。
- 用户可通过时间选择器查询其他范围。
- 旧书签或旧标签页 URL 中的 `range` 会覆盖全局默认值，应重新打开空白 Explore 页面验证。
- 单次默认最多返回 500 行，数据源请求超时为 60 秒；完整匹配数量由统计面板提供。
- provisioning 数据源固定 UID `victorialogs-ds` 且不可在 UI 中修改，避免账号之间配置漂移。
- Query/Multi 变量的 All 固定展开为 `*`，禁止枚举全部服务和 Pod。
- Grafana 容器使用 CPU、内存和 PID 上限；健康探测本身最多等待 5 秒。

查询转圈不等于后端并发不足。先检查浏览器请求、Grafana 日志和 VictoriaLogs 指标，详细流程见 [Grafana/VictoriaLogs 查询性能与升级运行手册](../../docs/grafana-victorialogs-query-performance-runbook.md)。

## 4. 生产日志检索大屏

`dashboards/vvg-log-search.json` 提供面向研发和运维的统一检索入口：

- 默认时间范围为最近 15 分钟，默认命名空间为 `jwxt-prod`。
- 命名空间、服务（`container`）、Pod 和日志级别均为动态联动下拉框。
- 顶部 `message` 使用 LogsQL word filter；`*` 表示全部，输入关键词或短语后，匹配内容会在日志明细中高亮。
- `message 多条件过滤` 使用 Business Text 渲染紧凑的行式“包含/不包含”条件，并通过一个全局 AND/OR 组合。编辑过程不查询，只有点击“应用过滤”才更新隐藏变量并刷新四个面板；“重置”恢复零条件。
- 条件状态随 Dashboard URL 保存，刷新和复制链接后可恢复；普通条件最多 20 条。高级 LogsQL 仅允许过滤条件，不接受管道。
- 页面包含匹配日志数、错误/严重日志数、按级别趋势和日志明细；自动刷新默认关闭。
- 日志概览与趋势共用一个折叠行：左侧 `19/24` 宽度显示趋势图，右侧 `5/24` 宽度上下放置两个统计数字。日志明细由单独的行边界保护，不会随概览和趋势一起折叠。
- 趋势图固定使用 Explore 的日志级别颜色，`warn` 在图例中显示为 `warning`，不会因序列出现顺序改变颜色。
- 当前数据没有 `cluster` 流字段，因此集群控件只显示 `生产 CCE`。多集群接入时应先由 Vector 写入稳定的 `cluster` 流字段，再把该变量改成动态查询，不能用节点名代替集群。

Dashboard provider 每 10 秒扫描一次目录。新增或更新 JSON 后无需重启 Grafana；生产部署时先把文件写入临时路径，再原子替换目标文件。

修改动态过滤器时先编辑 `scripts/render-vvg-message-filter.mjs`，再运行 `node scripts/render-vvg-message-filter.mjs` 生成面板模板和 Dashboard；不要分别手改两份生成结果。

完整的数据契约、三种导入方式、验证、回滚和 AI agent 操作边界见 [生产日志检索大屏配置与导入指南](../../docs/grafana-victorialogs-log-search-dashboard-guide.md)。

## 5. Gateway ClickHouse 可选路线

仓库不提供第二套 Grafana服务。需要 Gateway结构化日志大屏时，在本 Compose上叠加
`routes/gateway-clickhouse/compose.override.example.yml`，并发布包含
`grafana-clickhouse-datasource@4.5.1` 的新插件 release。默认 VVG-only 配置不加载
Gateway datasource，也不会要求 ClickHouse密码。

```bash
# .env 中同时设置新的 GRAFANA_PLUGINS_DIR、精确额外插件和只读密码。
sudo bash ../../scripts/install-grafana-plugins.sh .env

docker compose --env-file .env \
  -f docker-compose.yml \
  -f routes/gateway-clickhouse/compose.override.example.yml \
  config --quiet
```

完整启用和验证见
[Grafana Gateway ClickHouse可选路线](routes/gateway-clickhouse/README.md)。

## 6. 安全升级

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
docker exec grafana grafana cli --pluginsDir /var/lib/grafana-plugins plugins ls
curl -fsS http://127.0.0.1:3000/api/health
docker logs --since 10m grafana 2>&1 \
  | grep -E 'level=error|panic|migration failed|signature.*invalid' || true
```

回滚到 Grafana 12 时不能只切旧镜像。必须停止新容器，同时恢复升级前 Compose、插件目录和 `grafana.db`，否则旧版本可能读取迁移后的不兼容状态。

## 7. 常见问题

### 插件下载卡住

不要在生产启动配置中临时加入在线插件安装变量。在有网络的受控主机重新生成一个新的版本化插件包，验证清单后再传到生产并切换 `GRAFANA_PLUGINS_DIR`。

### 数据源不可用

从 Grafana 主机验证：

```bash
curl -fsS "${VICTORIALOGS_URL}/health"
curl -fsS "${VICTORIALOGS_URL}/metrics" | head
```

跨主机部署不能把数据源写成 `localhost`；只有 VictoriaLogs 与 Grafana 位于同一 Docker 网络时才可使用容器名。
