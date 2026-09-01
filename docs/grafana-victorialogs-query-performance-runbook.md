# Grafana/VictoriaLogs 查询性能与升级运行手册

> 验证基线：Grafana `13.2.0-ubuntu`、VictoriaLogs 数据源插件 `0.31.0`、VictoriaLogs `v1.52.0`
> 最后验证：2026-09-01
> 适用场景：Grafana Explore -> VictoriaLogs 单节点

本文来自一次真实生产排查和升级。核心结论是：Grafana 查询按钮持续转圈不等于 VictoriaLogs 查询慢，也不等于并发上限太低。必须先区分浏览器取消、Grafana/插件错误、LogsQL 语法、网络和 VictoriaLogs 执行时间。

## 1. 请求链路

一次 Explore 日志查询通常不止一个请求：

```text
Browser
  -> Grafana /api/ds/query
     -> victoriametrics-logs-datasource
        -> /select/logsql/query  日志列表
        -> /select/logsql/hits   日志量直方图
```

默认时间范围越大、查询越宽泛，两个后端请求扫描的数据越多，浏览器还要渲染更多行和直方图。因此仓库默认值为：

- 新 Explore 页面：最近 15 分钟。
- 返回行数：最多 2000。
- 数据源超时：60 秒。

用户仍可选择其他时间范围。旧书签和旧标签页 URL 中的 `panes`/`range` 会覆盖服务器默认值；验证新默认时必须重新打开不带查询状态的 `/explore`。

## 2. 已验证的现场证据

2026-09-01 的点时样本：VictoriaLogs 宿主机 4 核，容器限制 3 CPU/5 GiB，查询并发上限 4。

| 请求 | 15 分钟 | 60 分钟 |
|---|---:|---:|
| `/select/logsql/query`，最多 2000 行 | 约 0.25-0.32 秒 | 约 0.29 秒 |
| `/select/logsql/hits` | 约 0.05-0.06 秒 | 约 0.12 秒 |

同时：

```text
vl_concurrent_select_capacity=4
vl_concurrent_select_limit_reached_total=0
vl_concurrent_select_limit_timeout_total=0
```

Grafana 中异常请求大多在约 0.1-0.6 秒时由浏览器取消，服务端记录为 `499/context canceled`。这说明当时的“转圈”不是 VictoriaLogs 长时间执行或并发排队导致的。

这些数值只是当时数据量和硬件下的样本，不是长期容量证明。每次调优都应重新记录时间窗、查询、资源和指标。

## 3. 只读排查顺序

### 3.1 固定观察时间和版本

```bash
date -Is
docker inspect -f '{{.Config.Image}} {{.State.Status}}/{{.State.Health.Status}}' grafana
docker exec grafana grafana server -v
docker exec grafana grafana cli plugins ls
curl -fsS http://127.0.0.1:3000/api/health
```

不要先重启。先确认是否只有某个账号、浏览器或旧 Explore URL 复现。

### 3.2 区分状态码

```bash
docker logs --since 2h grafana 2>&1 | grep -E \
  'path=/api/ds/query|context canceled|cannot parse|timeout|status=5[0-9][0-9]'
```

- `499` + `context canceled`：客户端在服务端完成前关闭请求。常见于页面重新渲染、切换查询、旧标签页状态冲突、刷新或网络中断。
- `500` + `cannot parse query`：LogsQL 语法错误，通常几毫秒内失败；增加并发无效。
- `502/503/504`：检查反向代理、插件进程、VictoriaLogs 可达性和服务状态。
- 请求持续接近数据源 timeout：再检查后端执行、排队和资源。

日志可能包含查询正文和用户标识。排查输出只保留必要错误，交付报告中应脱敏。

### 3.3 绕过 Grafana 测量 VictoriaLogs

```bash
END=$(date +%s)

for MINUTES in 15 60; do
  START=$((END - MINUTES * 60))
  STEP=$((MINUTES * 60 / 100))

  curl -fsSG -o /dev/null \
    -w "${MINUTES}m logs http=%{http_code} total=%{time_total}s first_byte=%{time_starttransfer}s\n" \
    http://127.0.0.1:9428/select/logsql/query \
    --data-urlencode 'query=* | sort by (_time) desc' \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}" \
    --data-urlencode 'limit=2000'

  curl -fsSG -o /dev/null \
    -w "${MINUTES}m volume http=%{http_code} total=%{time_total}s first_byte=%{time_starttransfer}s\n" \
    http://127.0.0.1:9428/select/logsql/hits \
    --data-urlencode 'query=* | sort by (_time) desc' \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}" \
    --data-urlencode "step=${STEP}s"
done
```

若后端请求很快而 Grafana 仍转圈，继续检查浏览器、反向代理和插件，不要扩大后端并发。

### 3.4 检查查询并发和慢查询

```bash
curl -fsS http://127.0.0.1:9428/metrics | grep -E \
  '^(vl_concurrent_select_capacity|vl_concurrent_select_current|vl_concurrent_select_limit_reached_total|vl_concurrent_select_limit_timeout_total|vl_slow_queries_total) '

docker stats --no-stream victorialogs
docker logs --since 2h victorialogs 2>&1 | grep -Ei 'slow query|timeout|panic|error'
```

提高并发前必须同时满足：

1. `limit_reached_total` 或 `limit_timeout_total` 在真实业务查询期间持续增长。
2. CPU、内存、磁盘有明确余量。
3. 默认时间范围、返回行数和 LogsQL 已收窄。

每次只提高一个小档位并复测 P95/P99。并发计数从未触顶时，提高上限只会增加潜在资源争用。

## 4. LogsQL 常见错误

LogsQL 的 `|` 后面必须是 `sort`、`stats`、`limit` 等 pipe 操作，不能直接放搜索值。

错误：

```logsql
admin-api/teach/shop-car/delete | 2675396
```

正确的词/短语过滤：

```logsql
"admin-api/teach/shop-car/delete" "2675396"
```

字段正则必须使用英文半角引号，并在字段名后加冒号：

```logsql
_msg:~"20260901143336\\..*"
```

不要使用中文弯引号：

```text
_msg:~”value“
```

优先使用词过滤和短语过滤；只有需要匹配单词内部子串或模式时才使用正则。把选择性最高、执行最快的过滤条件放在左侧。

官方语法参考：<https://docs.victoriametrics.com/victorialogs/logsql/>

## 5. Grafana 安全升级

### 5.1 固定版本和插件

执行时解析当前稳定版，记录精确 Grafana tag、插件版本和镜像摘要。本次验证组合：

```text
grafana/grafana:13.2.0-ubuntu
victoriametrics-logs-datasource: 0.31.0
```

不要在生产 Compose 中设置运行时在线插件安装。插件下载失败可能在旧目录已移除、新目录未就绪时阻塞 Grafana 启动。

### 5.2 在受控机器构建

```bash
cd docker-compose/grafana
docker build \
  --build-arg GRAFANA_VERSION=13.2.0-ubuntu \
  --build-arg VICTORIALOGS_PLUGIN_VERSION=0.31.0 \
  -t vvg-grafana:13.2.0-plugin0.31.0 .

docker run --rm vvg-grafana:13.2.0-plugin0.31.0 \
  grafana cli plugins ls
```

生产服务器无法访问插件站点时，在有代理的受控工作机完成构建并推送私有仓库。生产启动只拉取已验证镜像。

### 5.3 一致性备份

Grafana 使用 SQLite 时，停止服务后再复制数据库和插件目录：

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/data/grafana/backups/grafana-pre-upgrade-${STAMP}"
install -d -m 0700 "${BACKUP}"

docker compose --env-file .env stop -t 60 grafana
cp -a docker-compose.yml .env dashboards datasources grafana-data "${BACKUP}/"
sha256sum "${BACKUP}/docker-compose.yml" \
          "${BACKUP}/grafana-data/grafana.db" \
  > "${BACKUP}/checksums.sha256"
docker compose --env-file .env up -d --no-deps grafana
```

备份目录权限必须限制，`.env` 中可能包含初始管理员密码。

### 5.4 隔离数据副本演练

复制一致性备份，在仅绑定 loopback 的临时端口启动新版本。不要让测试容器指向正式 `grafana-data`。

```bash
docker run -d --name grafana-upgrade-test \
  --user 472 \
  -p 127.0.0.1:13001:3000 \
  -v /data/grafana/test-data:/var/lib/grafana \
  -v "$PWD/dashboards:/etc/grafana/provisioning/dashboards:ro" \
  -v "$PWD/datasources:/etc/grafana/provisioning/datasources:ro" \
  -e VICTORIALOGS_URL=http://VICTORIALOGS_HOST:9428 \
  -e GF_EXPLORE_DEFAULTTIMEOFFSET=15m \
  vvg-grafana:13.2.0-plugin0.31.0
```

必须确认：数据库 migration 完成、插件签名有效、数据源注册、`/api/health` 正常、没有 panic/fatal/migration failed。

### 5.5 正式切换

只重建批准的 Grafana 服务：

```bash
docker compose --env-file .env config --quiet
docker compose --env-file .env stop -t 60 grafana
docker compose --env-file .env up -d --no-deps --force-recreate grafana
```

验证容器健康、内部 `/api/health`、公网入口、插件版本和一条 15 分钟真实查询。不要用服务器 loopback 成功代替外部网络验证。

## 6. 回滚

Grafana 13 会迁移 SQLite 和统一存储。回滚时：

1. 停止并移走失败的新容器和已迁移数据目录。
2. 恢复升级前 Compose、`.env`、插件目录和整个 `grafana-data`。
3. 使用精确旧镜像重建 Grafana。
4. 验证历史 dashboard、数据源、用户登录和查询。

不能只切回 Grafana 12 镜像继续使用已经由 Grafana 13 迁移的数据库。

## 7. 验收清单

- Grafana 容器 `running/healthy` 且 `RestartCount=0`。
- `/api/health` 返回预期版本和 `database=ok`。
- `grafana cli plugins ls` 只有一个 VictoriaLogs 插件版本。
- 启动日志确认 `GF_EXPLORE_DEFAULTTIMEOFFSET=15m`。
- 升级后没有 `level=error`、panic、migration failed 或 invalid signature。
- 内部和公网入口都验证成功。
- 15 分钟日志和直方图请求为 200，并记录耗时。
- VictoriaLogs 并发触顶/超时计数没有异常增长。
- 同机其他容器的启动时间未改变。
- 备份 checksum 通过，测试容器和测试数据已清理。
