# Grafana/VictoriaLogs 查询性能与升级运行手册

> 验证基线：Grafana `13.2.0-ubuntu`、VictoriaLogs 数据源插件 `0.31.0`、Business Text `6.3.0`、VictoriaLogs `v1.52.0`
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
- 返回行数：最多 500；完整数量通过 stats 查询获取。
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

### 2.1 All 展开与 Grafana 主机失速案例

2026-09-01 的另一轮现场查询中，Dashboard 的 Query/Multi 变量启用了 All，但没有配置自定义 `allValue`。Grafana 因而把 All 展开成 21 个服务、44 个 Pod 和 5 个级别；同类 `message` 查询在 VictoriaLogs 记录到 `64.308s` 慢查询，入口 Nginx 在 `60s` 返回 `504`。

同一时间窗绕过 Grafana 后，命名空间查询约 `0.013s`，短语搜索约 `0.558s`，简化后的 message 正则约 `0.505s`，并发触顶和排队超时计数均为 0。根因不是 VictoriaLogs 并发不足，而是变量展开和 Grafana 主机资源失控。

Grafana 主机当时只有 4 核、15 GiB 内存且无 Swap，Grafana 与 VictoriaLogs 数据源插件进程合计占用约 8 GiB，系统 load 超过 350，I/O wait 达到 92%-94%，Docker 与 Grafana 健康接口均无法及时返回。只重启 Grafana 后，其内存回落到约 0.4 GiB、插件约 0.02 GiB，VVG 健康接口恢复到约 `0.002s`。随后用 4 GiB 容器边界复测 2000 行日志明细时，插件进程再次增长到约 3.8 GiB并被 cgroup OOM 终止，确认返回行数也是独立放大因素。

因此仓库基线要求：

- 四个 Query/Multi 变量必须设置 `allValue: "*"`。
- 数据源和大屏日志明细默认最多返回 500 行；统计数量不受该展示上限影响。
- Dashboard 文本变量使用 `_msg:$message` word filter 和默认值 `*`，让插件正确引用中文并返回 `searchWords` 以支持匹配词高亮；不要使用 `message:~$message` 或未引用的 `| $message`。
- Grafana 默认限制为 2 CPU、4 GiB 内存和 512 PID；需要调整时必须记录共享主机余量。
- 健康探测自身最多等待 5 秒，避免故障时无限堆积探测进程。
- Nginx 的 60 秒超时是保护边界，不应通过提高超时掩盖慢查询。

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
marcusolsson-dynamictext-panel: 6.3.0
```

不要在生产 Compose 中设置运行时在线插件安装。插件下载失败可能在旧目录已移除、新目录未就绪时阻塞 Grafana 启动。

对 bind mount `/var/lib/grafana` 的部署，插件必须位于数据挂载之外。本仓库把版本化宿主机目录只读挂载到 `/var/lib/grafana-plugins`，设置 `GF_PATHS_PLUGINS`，并禁用 Grafana 默认插件预安装和自动更新。这样 Grafana 镜像升级与插件升级相互独立，也避免 SQLite 数据卷遮住插件或后台任务写入不可变 release。

### 5.2 在受控机器发布插件包

```bash
cd docker-compose/grafana
sudo bash ../../scripts/install-grafana-plugins.sh .env
```

该命令只生成固定版本的外置插件包，不构建 Grafana 镜像。生产服务器无法访问插件站点时，在有代理的同架构 Linux 主机生成 release 目录，归档、计算 SHA-256 后传输；生产启动只读取已验证的只读目录。

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
  grafana/grafana:13.2.0-ubuntu
```

必须确认：数据库 migration 完成、插件签名有效、数据源注册、`/api/health` 正常、没有 panic/fatal/migration failed。

SQLite 升级启动时可能出现 info 级 `database is locked` 并自动重试。只有同时满足以下条件才可判定为已恢复的短暂竞争：migration 明确完成、健康和数据源 API 均为 200、容器无重启，且后续至少 5 分钟没有新的 lock retry。若计数持续增长或出现 error/fatal，不得继续切换。

### 5.5 正式切换

只重建批准的 Grafana 服务：

```bash
docker compose --env-file .env config --quiet
docker compose --env-file .env stop -t 60 grafana
docker compose --env-file .env up -d --no-deps --force-recreate grafana
```

验证容器健康、内部 `/api/health`、公网入口、插件版本和一条 15 分钟真实查询。不要用服务器 loopback 成功代替外部网络验证。

### 5.6 旧版 Docker Compose 兼容边界

执行前必须用目标服务器上的实际 Compose 二进制验证候选文件。旧版 `docker-compose 1.25.x` 可能不支持现代无版本 Compose，也可能拒绝 `mem_limit`、`pids_limit` 或 `healthcheck.start_period`；不要通过反复猜测版本字段直接修改正式文件。

若暂时不能升级 Compose：

1. 保留该主机已验证的 Compose 文件版本，只提交它能够解析的健康探测、只读 provisioning 挂载和日志轮转配置。
2. 重建 Grafana 后使用 Docker runtime 设置边界：

   ```bash
   docker update \
     --cpus 2 \
     --memory 4g \
     --memory-swap 4g \
     --pids-limit 512 \
     grafana
   ```

3. `memory-swap` 与 `memory` 相等表示不提供额外 Swap。应用后必须通过 `docker inspect` 核对 `NanoCpus`、`Memory`、`MemorySwap` 和 `PidsLimit`。
4. 普通 container restart 会保留 runtime 限制；`--force-recreate` 会创建新容器并丢失这些限制，所以每次重建后都必须重新执行并验证。长期方案仍是升级到仓库验证过的 Compose 版本。

测试环境 Dashboard 应从生产 JSON 派生，只调整标题、环境标签、集群显示名和默认 namespace。UID、查询表达式、All 通配值、500 行上限、折叠结构、级别颜色、message 高亮逻辑、Business Text 面板代码和隐藏变量必须保持一致，避免维护两套行为不同的大屏。

## 6. 回滚

Grafana 13 会迁移 SQLite 和统一存储。回滚时：

1. 停止并移走失败的新容器和已迁移数据目录。
2. 恢复升级前 Compose、`.env`、Dashboard、插件目录和整个 `grafana-data`。
3. 使用精确旧镜像重建 Grafana。
4. 验证历史 dashboard、数据源、用户登录和查询。

不能只切回 Grafana 12 镜像继续使用已经由 Grafana 13 迁移的数据库。

## 7. 验收清单

- Grafana 容器 `running/healthy` 且 `RestartCount=0`。
- `/api/health` 返回预期版本和 `database=ok`。
- `grafana cli plugins ls` 同时显示 VictoriaLogs `0.31.0` 和 Business Text `6.3.0`，没有重复版本。
- 启动日志确认 `GF_EXPLORE_DEFAULTTIMEOFFSET=15m`。
- 升级后没有 `level=error`、panic、migration failed 或 invalid signature。
- 内部和公网入口都验证成功。
- 15 分钟日志和直方图请求为 200，并记录耗时。
- 多条件表单编辑不触发查询，Apply/Reset、AND/OR、URL 恢复和 20 条边界均验证成功。
- VictoriaLogs 并发触顶/超时计数没有异常增长。
- 同机其他容器的启动时间未改变。
- 备份 checksum 通过，测试容器和测试数据已清理。
