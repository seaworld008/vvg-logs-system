# Vector -> ClickHouse -> Grafana 网关日志专区

本专区提供一套可复制的网关访问日志方案：Kubernetes 节点上的 Vector 读取 Gateway 容器日志，解析为稳定字段后写入单节点 ClickHouse，Grafana 使用 ClickHouse datasource 展示 QPS、PV/UV、状态码、延迟分位数、后端分布、慢接口和请求明细。

验证基线：Vector `0.58.0`、ClickHouse `26.8.2.7-alpine`、Grafana ClickHouse datasource `4.5.1`、DB-IP City Lite `2026-09`。Grafana 本体由使用方现有平台管理，本专区不负责升级 Grafana。仓库中的完整 65 面板 KubeDoor Gateway Dashboard 是默认大屏。

## 目录

```text
clickhouse-gateway/
  clickhouse/
    docker-compose.yml
    config/observability.xml
    initdb/001-gateway-schema.sql
  vector/
    vector-k8s-containerd.yaml
    geoip/NOTICE.md
  grafana/
    datasources/clickhouse.yaml
    dashboards/dashboard.yaml
    dashboards/gateway-observability.json
```

生产操作前必须阅读 [Vector/ClickHouse/Grafana 运行手册](../docs/vector-clickhouse-gateway-runbook.md)。架构取舍见 [ADR-001](../docs/decisions/0001-vector-clickhouse-gateway.md)。

![Gateway ClickHouse 日志分析大屏](../docs/images/clickhouse-gateway-overview.png)

## 数据流

```text
Gateway stdout
  -> containerd CRI 文件
  -> Vector file source + checkpoint
  -> DB-IP City Lite MMDB 地域补全
  -> VRL 字段解析和脱敏失败诊断
  -> 1 GiB/节点 disk_v2 buffer
  -> gzip JSONEachRow + HTTP acknowledgement
  -> ClickHouse MergeTree / 30 天 TTL
  -> Grafana ClickHouse datasource
  -> Gateway 请求日志分析 Dashboard
```

## 部署前替换

公开模板故意保留以下占位符，未替换不得部署：

- `registry.example.com/observability/...`：组织私有镜像地址；
- `CHANGE_ME_BEFORE_DEPLOY`：ClickHouse 初始写入密码；
- `clickhouse.example.internal`：Vector/Grafana 可访问的内网地址；
- `REPLACE_GATEWAY_POD_GLOB_REPLACE_NAMESPACE_REPLACE_CONTAINER_GLOB.log`：目标 Gateway 容器日志 glob；
- `REPLACE_LOGICAL_GATEWAY_ID`：写入 `server_ip` 字段的稳定逻辑标识。

不要把真实地址、密码、Token、业务域名或服务器清单提交到 Git。生产 Compose 按现有运维习惯使用单文件配置；若密码直接写入 Compose，必须将文件设为 `0600`，并确保其未被 Git 跟踪。

## 1. 发布 ClickHouse 镜像

在可访问 Docker Hub 的受控机器拉取官方精确版本，记录官方 RepoDigest，再推送到私有仓库：

```bash
docker pull clickhouse/clickhouse-server:26.8.2.7-alpine
docker image inspect clickhouse/clickhouse-server:26.8.2.7-alpine \
  --format 'id={{.Id}} digests={{json .RepoDigests}} size={{.Size}}'

docker tag clickhouse/clickhouse-server:26.8.2.7-alpine \
  registry.example.com/observability/clickhouse/clickhouse-server:26.8.2.7-alpine
docker push registry.example.com/observability/clickhouse/clickhouse-server:26.8.2.7-alpine
```

生产机无法出网时使用 `docker save | gzip`、SHA-256、SSH 传输和 `docker load`。Compose 设置 `pull_policy: never`，防止启动过程临时联网。

## 2. 启动 ClickHouse

先修改 Compose 中的镜像、密码和资源边界，再创建目录：

```bash
cd clickhouse-gateway/clickhouse
install -d -m 0750 data logs
chmod 0600 docker-compose.yml
docker compose -f docker-compose.yml config --quiet
docker compose -f docker-compose.yml up -d
docker compose -f docker-compose.yml ps
```

`001-gateway-schema.sql` 只在空数据目录首次初始化时运行。已有 ClickHouse 不会自动改表，必须使用运行手册中的备份、数据副本和显式迁移流程。

已有部署升级到 ClickHouse 26.8 前，必须扫描 Vector 配置中的 `to_unix_timestamp(..., unit: "milliseconds")`。用于 `DateTime64(3)` 的事件时间和采集时间必须先改为 RFC3339 字符串，并在当前版本验证等价写入；否则新版本可能把毫秒整数写入异常远期分区并被 TTL 清理。

模板使用月分区、紧凑主键和 30 天业务 TTL。不要复制某个现场“把大部分列都放入 ORDER BY”的历史表结构；超宽排序键会放大主索引、合并和写入成本。

## 3. GeoIP 数据

GeoIP 不再从现场华为云、OBS 或业务 CDN 下载。模板固定使用本仓库 GitHub Release 中的 DB-IP City Lite `2026-09`，initContainer 对本地持久文件做 SHA-256 检查，仅在缺失或不匹配时重新下载，并在校验成功后原子替换。

版本、大小、校验值、授权与归属见 [GeoIP 数据声明](vector/geoip/NOTICE.md)。更新时必须发布新的月份资产并修改 manifest 中的文件名、URL 和 SHA-256；禁止使用 `latest`。DB-IP City Lite 使用 CC BY 4.0，Dashboard 中的 `IP Geolocation by DB-IP` 链接必须保留。

只改 URL 不会更新已通过旧 SHA 校验的本地文件。文件名也不代表 MMDB metadata 中的真实数据库类型；变更数据提供方时必须同步核对 `type: mmdb` 和 VRL 嵌套字段映射，详细门禁见运行手册。

## 4. 创建 Vector Secret

Vector 通过 directory secret backend 读取凭据，密码不会进入 ConfigMap 或进程环境：

```bash
kubectl -n logging create secret generic vector-clickhouse-auth \
  --from-literal=username='vector_ingest' \
  --from-literal=password='REPLACE_WITH_STRONG_PASSWORD'
```

这条命令会进入 shell history。生产应从受控密码文件、Secret 管理系统或关闭历史记录的受控会话创建，不要把实际值粘贴到工单、PR 或 Agent 对话。

## 5. 部署 Vector

修改 manifest 中的镜像、endpoint、glob、namespace 和逻辑网关标识，然后验证：

```bash
kubectl apply --dry-run=server -f vector/vector-k8s-containerd.yaml
kubectl apply -f vector/vector-k8s-containerd.yaml
kubectl -n logging rollout status daemonset/vector-clickhouse-gateway --timeout=300s
```

关键可靠性基线：

- `ignore_checkpoints: false`，禁止每次重启从头重读；
- 每节点独立 hostPath，禁止与其他 Vector 共享 `data_dir`；
- `disk` buffer、`when_full: block`、sink acknowledgement；
- ClickHouse 异步落盘最长等待 120 秒，Vector 请求超时必须更长，本模板为 180 秒；
- 不设置有限 `retry_attempts`，让磁盘缓冲和退避承担短时后端维护；
- 解析失败只输出技术元数据，不复制原始 header/body 到无界文件。
- GeoIP MMDB 与 checkpoint/buffer 共用该 Vector 专属 hostPath，但使用独立 `geoip/` 子目录；不得与其他 Vector DaemonSet 共用状态目录。

## 6. 接入 Grafana

在现有 Grafana 中预先安装并固定 `grafana-clickhouse-datasource 4.5.1`。生产启动不得在线安装插件。把 `CLICKHOUSE_GRAFANA_PASSWORD` 由 Kubernetes Secret 或现有密钥系统注入 Grafana 环境，然后挂载：

- `grafana/datasources/clickhouse.yaml` 到 datasource provisioning 目录；
- `grafana/dashboards/dashboard.yaml` 和 `gateway-observability.json` 到独立 Dashboard provisioning 目录。

Grafana 账号应使用只读 ClickHouse 用户，不要复用 `vector_ingest` 或 `default` 管理账号。数据源 UID 固定为 `gateway-clickhouse`，Dashboard UID 固定为 `vvg-clickhouse-gateway`。

`gateway-observability.json` 是从生产 KubeDoor Gateway 大屏脱敏得到的完整默认 Dashboard。重新导出时运行：

```bash
GATEWAY_SENSITIVE_DOMAIN_SUFFIXES=corp.example \
  node scripts/sanitize-clickhouse-gateway-dashboard.mjs RAW_GRAFANA_API_EXPORT.json
node scripts/validate-clickhouse-gateway.mjs
```

把 `corp.example` 替换为现场真实域名后缀；它只通过进程环境传入，不写入仓库。清洗器固定 UID、最近 15 分钟、自动刷新关闭、默认表名和 DB-IP 归属链接，并替换生产 datasource UID、域名和地址。

## 7. 验收

```bash
bash scripts/validate-clickhouse-gateway.sh --static
bash scripts/validate-clickhouse-gateway.sh --runtime

kubectl -n logging get pods -l app=vector-clickhouse-gateway -o wide
kubectl -n logging logs -l app=vector-clickhouse-gateway --since=15m \
  | grep -E 'Retries exhausted|component_events_dropped|ERROR' || true
```

还必须确认 ClickHouse 行数持续增加、`max(createdtime)` 距当前时间处于目标范围、无异步写入失败、所有 Vector Pod 重启数为零，并连续观察至少 15 分钟。仅 `Running` 或 HTTP 200 不等于端到端验收通过。

## 字段契约

Dashboard 依赖 `timestamp`、`createdtime`、`server_ip`、`domain`、`status`、`business_code`、`top_path`、`path`、`upstreamhost`、`responsetime`、`client_ip`、`request_length` 和 `response_length`。添加字段可以向后兼容；重命名、改变类型或删除字段必须同步 SQL、Vector 和 Dashboard，并在数据副本上验证。

`query`、`referer`、User-Agent、用户/租户/应用标识可能属于敏感数据。接入前应完成隐私审查；默认不要采集请求头、请求体、响应体或认证信息。
