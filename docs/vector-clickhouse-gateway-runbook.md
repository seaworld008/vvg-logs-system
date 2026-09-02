# Vector -> ClickHouse -> Grafana 网关日志运行手册

> 验证基线：Vector `0.58.0`、ClickHouse `26.8.2.7-alpine`、Grafana ClickHouse datasource `4.5.1`
>
> 适用场景：Kubernetes/containerd Gateway stdout -> Vector DaemonSet -> 单节点 ClickHouse -> 现有 Grafana

本手册供 AI Agent 和运维人员执行新部署、升级、故障定位和回滚。真实地址、密码、镜像仓库、集群清单和业务日志正文不得进入 Git、PR、Release 或截图。

## 1. 先确认边界和所有权

```bash
docker inspect clickhouse --format '{{json .Config.Labels}}'
docker inspect clickhouse --format '{{json .Mounts}}'
docker inspect clickhouse --format '{{.Config.Image}} {{.Image}}'
docker compose -f /path/to/docker-compose.yml config --quiet

kubectl get daemonset,pod -A -o wide | grep -i vector
kubectl -n logging get daemonset vector-clickhouse-gateway -o yaml
```

Compose project label、working directory、config files、mount source 和依赖关系共同决定服务所有权。禁止仅凭镜像名删除“旧容器”。只改获批的 ClickHouse 和对应 Vector；Grafana、VictoriaLogs、业务 Pod 和其他监控服务保持不动。

## 2. 只读基线

记录以下信息：

- ClickHouse 版本、镜像 ID/RepoDigest、运行时长、重启和 OOM；
- Compose、配置、users、数据和日志挂载；
- 宿主机 CPU、内存、磁盘、inode 和 Docker RootDir；
- 所有业务表 DDL、行数、分区、active/inactive parts、mutation；
- `system.asynchronous_insert_log`、`system.errors`、system log 表体积；
- Vector 镜像、checkpoint、buffer、近 24 小时重试/丢弃；
- Grafana datasource 类型/UID/插件版本和 Dashboard UID。

```sql
SELECT version(), uptime(), timezone();
SELECT database, table, active, count(), sum(rows), formatReadableSize(sum(bytes_on_disk))
FROM system.parts GROUP BY database, table, active ORDER BY sum(bytes_on_disk) DESC;
SELECT status, count(), min(event_time), max(event_time)
FROM system.asynchronous_insert_log
WHERE event_time >= now() - INTERVAL 48 HOUR GROUP BY status;
SELECT database, table, mutation_id, command, is_done, latest_fail_reason
FROM system.mutations WHERE NOT is_done;
```

## 3. 版本选择与镜像交付

执行时解析最新非 draft、非 prerelease 的稳定/LTS 版本，不永久假定本文版本仍是最新。生产日志库优先选择当前 LTS 的最新 patch，而不是刚发布的普通 feature release。

官方镜像必须先在受控机器验证版本、Image ID 和 RepoDigest，再推入私有仓库。生产无法出网时：

1. `docker save | gzip`；
2. 生成 SHA-256；
3. 传到镜像中转机并再次校验；
4. `docker load`、打私库精确 tag、push；
5. 记录私库 RepoDigest；
6. 生产加载相同归档或从私库拉取；
7. 比较 Image ID，并运行 `clickhouse server --version`；
8. 删除传输归档。

不要把 Docker Hub `latest`、私库浮动 tag 或运行时在线拉取作为生产基线。

## 4. 一致性备份

单节点升级必须有停止写入后的物理快照。Vector 的持久 disk buffer 会在 ClickHouse 停机时接收新事件；先确认每节点容量足以覆盖预计窗口。

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/data/clickhouse/backups/pre-upgrade-${STAMP}"
install -d -m 0700 "${BACKUP}"
cp -a docker-compose.yml config users "${BACKUP}/"
docker inspect clickhouse > "${BACKUP}/inspect.before.json"

docker compose stop -t 120 clickhouse
cp -a --reflink=auto --sparse=always data "${BACKUP}/data"
sync
docker compose up -d --no-deps clickhouse
```

停止期间任何错误都必须触发原镜像恢复。记录源/备份字节数和文件数，但不能把运行中的源目录字节数与停机快照要求为完全相等；服务恢复后源目录会立即变化。

## 5. 数据副本隔离验证

禁止直接用唯一生产数据目录首次启动新版本。再复制一份静态备份，用 loopback 端口和候选只读配置启动：

```bash
cp -a "${BACKUP}/data" /data/clickhouse/validation/candidate-data

docker run --rm --name clickhouse-upgrade-test \
  -p 127.0.0.1:18123:8123 \
  -p 127.0.0.1:19000:9000 \
  -v /data/clickhouse/validation/candidate-data:/var/lib/clickhouse \
  -v /data/clickhouse/candidates/TARGET/config.d:/etc/clickhouse-server/config.d:ro \
  -v /data/clickhouse/candidates/TARGET/users.d:/etc/clickhouse-server/users.d:ro \
  --memory 8g --cpus 3 \
  registry.example.com/clickhouse/clickhouse-server:TARGET
```

验证版本、全部数据库/表 attach、DDL、行数、最近/历史查询、Grafana 代表性 SQL、配置加载、磁盘和日志。扫描 `broken part`、`UNKNOWN_SETTING`、`Cannot attach`、`corrupt`、`Exception`、`Fatal`。验证完成删除容器和 candidate-data，保留不可变备份。

## 6. ClickHouse 长期运行基线

- 容器健康检查执行认证后的 `SELECT 1`；
- `stop_grace_period: 2m`；
- 配置目录只读，data/logs 可写；
- 根据共享宿主机余量设置 CPU、memory、memory-swap 和 PID 上限；
- 单查询 `max_memory_usage` 必须低于容器上限；
- Docker stdout 日志有大小和文件数上限；
- system log 表默认 7 天 TTL；
- 业务表保留期写入 DDL，本模板为 30 天；
- 不定期执行 `OPTIMIZE TABLE ... FINAL`；让后台 merge 自主管理。

system log 表和版本迁移留下的 `*_0` 表可能远大于业务库。确认它们属于 `system`、没有业务依赖且已完成一致性备份后，可 `TRUNCATE` 当前 system log 并 `DROP` 历史 `*_0`；这些表的 DDL 注释明确标注可安全清理。禁止按名称批量删除业务库表。

## 7. Vector 与异步写入契约

ClickHouse `async_insert=1` 与 `wait_for_async_insert=1` 可合并小批次，并且只在成功落盘后确认。Vector 的 request timeout 必须大于 ClickHouse `wait_for_async_insert_timeout`。已验证基线：

```yaml
batch:
  max_bytes: 1048576
  max_events: 1000
  timeout_secs: 5
request:
  timeout_secs: 180
  retry_initial_backoff_secs: 1
  retry_max_duration_secs: 30
```

不要设置有限 `retry_attempts`。历史案例中服务端等待 120 秒，而客户端更早超时并在 3 次重试后丢弃整个批次。

### DateTime64 升级门禁

不要向 `DateTime64(3)` 发送 `to_unix_timestamp(..., unit: "milliseconds")` 的整数结果。一次从 ClickHouse 26.6 到 26.8 的真实升级中，26.6 将该整数解释为毫秒，26.8 则把新事件写入异常分区 `99991231`，随后业务 TTL 清除了这些行。Vector 必须显式发送字符串：

```vrl
.timestamp = format_timestamp!(event_time, "%+")
.createdtime = format_timestamp!(now(), "%+")
```

升级前在数据副本中至少插入一条与 Vector 完全相同编码的事件，再查询分区、`timestamp` 和 `createdtime`。仅验证旧数据可读不足以证明新写入兼容。

跨 Vector 版本迁移时，不要在线复制正在写入的 `disk_v2` buffer。已验证的安全顺序是：等待 sink `received-sent` 回到历史丢弃基线、冻结旧进程、只复制 checksum 一致的 checkpoint，并让新版本创建空 buffer。直接迁移活动 buffer 曾触发 ledger/data 文件不一致和 5 条不可处理记录。

### GeoIP 数据发布

生产旧库可能长期不更新。先读取 MMDB metadata 中的 `database_type`、`build_epoch`、语言和 IP 版本，不能只看文件 mtime。仓库默认使用 DB-IP City Lite `2026-09`，从固定 GitHub Release 下载，不依赖现场华为云、OBS 或业务 CDN。

升级 GeoIP 时：

1. 从 DB-IP 官方下载当月 City Lite MMDB，记录来源发布日期；
2. 验证数据库类型、IPv4/IPv6、`zh-CN`、城市、省份、国家和经纬度样本；
3. 生成 SHA-256，并在 Vector `0.58.0` 上用 `type: mmdb` 编译和查询；
4. 把 MMDB 发布为新的、非浮动 GitHub Release 资产；
5. 更新 manifest 的月份文件名、固定 URL 和 SHA-256；
6. 先滚动一个 Vector Pod，确认地域字段非空且无解析丢弃，再继续滚动；
7. 保留 Dashboard 的 `IP Geolocation by DB-IP` 归属链接。

initContainer 只在本地文件缺失或 SHA 不符时下载，先写随机临时文件，校验后 `chmod 0444` 并原子改名。下载失败应阻止 Vector 启动，不能静默回退到未知或未经校验的数据。

仅修改下载 URL 不会触发更新：如果 `target` 仍指向旧文件且旧 `expected` 与本地文件一致，initContainer 会在下载前直接退出。发布新库时必须同时更新目标文件名、URL 和 SHA-256。也不能根据 URL 或文件名判断数据库类型；先读取 MMDB metadata。若从 `GeoLite2-City` 切换到 `DBIP-City-Lite`，Vector 必须从 `type: geoip` 改为 `type: mmdb`，并把扁平的 `city_name`、`region_name`、`country_name` 读取改为 `city.names`、`subdivisions[].names`、`country.names` 和 `location` 嵌套字段。强制覆盖文件但不改这两处配置会导致 Vector 启动失败或地域字段全部为空。

## 8. Grafana

Grafana 只读账号只能 `SELECT` 所需数据库和 system 元数据。禁止把 ClickHouse 管理账号放入 datasource。默认最近 15 分钟、自动刷新关闭、明细最多 500 行；大范围分析先扩大聚合间隔，不先扩大 ClickHouse 并发。

验收完整 KubeDoor Gateway Dashboard：65 个面板全部加载，变量 All 不展开海量枚举，QPS/分位数查询命中时间过滤，慢接口和明细均有 LIMIT，两个 GeoIP 地图可查询，DB-IP 归属链接可见，浏览器控制台和 datasource health 无错误。完成后恢复最近 15 分钟和自动刷新关闭。

## 9. 正式切换

```bash
docker compose -f candidate.yaml config --quiet
docker compose -f current.yaml stop -t 120 clickhouse
mv candidate.yaml docker-compose.yml
docker compose -f docker-compose.yml up -d --no-deps clickhouse
```

只重建 ClickHouse。不要同时升级 Grafana、Vector 镜像或业务服务。等待 health 后比较：版本/digest、表数/行数、最新写入延迟、历史查询、parts、mutation、重启/OOM、Vector buffer 和错误增量。

## 10. 观察与回滚

至少连续观察 15 分钟，每分钟记录：

- ClickHouse health、版本、重启/OOM；
- `count()` 增量和 `dateDiff('second', max(createdtime), now())`；
- async insert 失败增量和 active parts；
- Vector Ready/Restart、request error、retry exhausted、buffer drop；
- Grafana datasource health 和代表性 Dashboard 查询。

失败时停止候选，恢复备份 Compose/配置和旧 data 目录，再启动旧镜像。新版本已经写入生产数据后，不得只切旧镜像；必须恢复对应的旧版本一致性数据快照，否则可能读取不兼容的磁盘格式。
