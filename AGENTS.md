# VVG Repository Agent Guide

本文件适用于整个仓库。AI Agent 或自动化修改本项目时，必须先读取本文件，再读取任务对应的运行手册。

## 必读顺序

1. `README.md`
2. `docs/ai-agent-operations-guide.md`
3. `docs/vector-victorialogs-latency-runbook.md`
4. `docs/grafana-victorialogs-query-performance-runbook.md`
5. `docs/grafana-victorialogs-log-search-dashboard-guide.md`
6. ClickHouse 网关链路任务再读 `docs/vector-clickhouse-gateway-runbook.md`
7. AutoMQ 日志缓冲任务再读 `docs/automq-log-buffer-runbook.md`
8. MCP 任务再读 `docker-compose/mcp-victorialogs/README.md`
9. 即将修改的 Compose、环境变量示例、Dashboard 生成器和校验脚本

## 不可破坏的基线

- 所有镜像和 Grafana 插件必须固定精确版本；禁止 `latest`。
- Grafana 正式启动不得联网安装插件。插件必须先发布到版本化宿主机目录，再只读挂载到 `/var/lib/grafana-plugins`。
- 外置插件目录必须位于 `/var/lib/grafana` 数据挂载之外；同时设置 `GF_PLUGINS_PREINSTALL_DISABLED=true` 和 `GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`。
- 密码、Token、服务器清单、真实内网地址和运行数据不得进入 Git、PR、Release 或截图。
- Dashboard UID `vvg-log-search`、VictoriaLogs datasource UID `victorialogs-ds`、默认 15 分钟、日志明细 500 行和 Query/Multi 变量 `allValue: "*"` 不得无证据修改。
- 日志趋势必须复用 Explore `Logs volume` 的 `hits` / `logsVolume` 查询、按 `level` 分组，并固定 `maxDataPoints: 100` 和 `barWidthFactor: 0.6`；禁止退回会产生亚像素稀疏柱的 `statsRange`。
- 测试和生产使用同一查询逻辑、面板代码、颜色和限制；只允许标题、集群显示名、环境标签和默认 namespace 不同。
- 只改获批服务。Grafana 变更不得顺带升级 VictoriaLogs、Vector 或业务服务。
- ClickHouse 网关链路固定 Dashboard UID `vvg-clickhouse-gateway` 和 datasource UID `gateway-clickhouse`；默认最近 15 分钟、自动刷新关闭、明细 500 行。

## VictoriaLogs MCP 专区

`docker-compose/mcp-victorialogs/` 使用官方 `mcp-victorialogs` 和官方 `vmauth`，不得复制实现 VictoriaLogs 查询 API 或自建另一套 MCP 协议服务。

- 测试和生产使用同一镜像 digest、工具集合、资源限制和查询保护，但必须部署两个实例并固定各自 VictoriaLogs 地址、租户和独立 Token；禁止用客户端 Header 或参数切换环境。
- 只暴露 `vmauth`。MCP 容器不得直接发布宿主机端口，`MCP_PASSTHROUGH_HEADERS` 必须保持未设置。
- 外部 MCP 请求必须使用独立 Bearer Token。MCP 到 VictoriaLogs 的内部 Token 与外部 Token 不得复用。
- 只开放 `query`、`hits`、`field_names`、`field_values` 和 `stats_query`。日志查询最多 500 行，字段值最多 100，后端超时不超过 20 秒，MCP 后端查询并发固定为 1。
- `AccountID` 和 `ProjectID` 必须由 `vmauth` 覆盖，禁止信任工具参数中的租户值；只允许批准的 `/select/logsql/*` 路径，禁止写入、管理、flags 和 metrics 路径代理到 VictoriaLogs。
- 主机部署目录固定为 `/data/vvg-mcp`。`.env`、`vmauth/auth.yml` 和 `secrets/client-bearer-token` 必须留在目标机、限制权限并被 Git 忽略。
- 单文件 bind mount 通过原子替换更新后必须只重建 `vmauth`，不能假定 HUP 会切换到新 inode。

## Vector -> ClickHouse -> Grafana 专区

`clickhouse-gateway/` 是结构化 Gateway 访问日志的独立方案，不得与 VictoriaLogs 原始日志链路混改。

- Vector 必须保留 checkpoint，使用每节点独立持久目录、disk buffer、`when_full: block` 和 sink acknowledgement。
- ClickHouse `wait_for_async_insert=1` 时，Vector 请求超时必须高于服务端异步写入等待；当前基线为 180 秒，禁止有限 `retry_attempts`。
- 解析失败不得把原始 header/body 写入无界文件，只允许脱敏技术诊断和计数。
- ClickHouse 使用精确 LTS patch 和私有镜像；Compose 单文件可保留，但实际密码文件必须 `0600` 且不得进入 Git。
- system log 必须有有限 TTL。清理 `system` 表前先验证其 DDL 注释、所有权和一致性备份，禁止按名称批量删除业务表。
- 已有业务表的分区、ORDER BY、TTL、Materialized View 和 projection 不得在镜像升级中顺带修改。新项目使用专区内的月分区和紧凑主键模板。
- Grafana 使用只读 ClickHouse 用户。不得把 `default` 管理账号或 Vector 写入账号复用到 datasource。
- GeoIP 使用固定 GitHub Release 中的 DB-IP City Lite、精确 SHA-256 和持久目录；禁止使用现场华为云/OBS/CDN 地址或浮动下载链接，Dashboard 必须保留 DB-IP 归属链接。
- KubeDoor Gateway Dashboard 的仓库 JSON 是默认大屏。导入 Grafana API 导出时运行 `node scripts/sanitize-clickhouse-gateway-dashboard.mjs RAW_EXPORT.json`，再运行校验；不得恢复为旧的 12 面板简化版。

## AutoMQ + 对象存储专区

`docker-compose/automq/` 是 VVG 与 Gateway 的可选 Kafka-compatible 持久缓冲层。

- 生产镜像必须先进入受控 Harbor/SWR并固定 tag 与 digest；正式启动不得在线拉取。
- 当前单节点、共享宿主机和单 OBS 桶是用户明确接受的受控例外，不得描述为官方生产高可用架构，也不得复制到其他环境作为默认值。
- AutoMQ 固定 `3 CPU / 6 GiB`，使用官方 Tiny 内存参数：Heap 1 GiB、Direct Memory 1.5 GiB、WAL cache 500 MiB、Block cache 100 MiB、upload threshold 60 MiB；不得取消 cgroup 边界或添加 Swap。
- data/ops/WAL 可复用同一物理桶但必须使用固定 bucket ID `0/1/0`；禁止把 OBS 普通文件夹当作 bucket prefix。桶必须 private、标准存储、SSE-OBS，且不能用生命周期提前删除活跃对象。
- 对华为云 OBS 不设置 `checksumAlgorithm`；必须完成小对象、multipart、读取校验、删除和 Broker 重启验证。
- Kafka 外部入口只绑定 VPC 内网地址，VPC 内工作负载可达，不配置源 IP 白名单，也不得发布公网；使用 `SASL_PLAINTEXT + SCRAM-SHA-512`，关闭自动建 Topic，producer/consumer/admin 使用独立用户和 ACL。
- VVG 与 Gateway 使用独立 Topic、consumer group和 Vector state。producer 使用 `disk + block`，consumer 依靠 Kafka offset并使用有界 `memory + block`。Gateway 原始 header/body禁止进入 AutoMQ；只允许解析和脱敏后的结构化事件。
- shadow 与 production producer 的 metrics hostPort相同，主切前必须先停止 shadow；shadow 与 production consumer不得同时写同一正式后端。
- 生产者清单必须由 `scripts/render-automq-vector-manifest.py` 从当前真实源 manifest生成，禁止用仓库公开示例覆盖现场解析、GeoIP或checkpoint。
- VVG/Gateway 直写配置必须长期保留；小到中等规模优先直写，中大规模且需要集中缓冲时再采用 AutoMQ + 对象存储。
- 本阶段不得停止或重建 `redis-v9`、`elk_redis`、Logstash、Kibana、Elasticsearch、VictoriaLogs、ClickHouse、Grafana或业务服务。

## Dashboard 修改

`scripts/render-vvg-message-filter.mjs` 是 message 多条件面板和紧凑布局的源。不要分别手改面板模板与 Dashboard：

```bash
node scripts/render-vvg-message-filter.mjs
node scripts/validate-vvg-message-filter.mjs
bash scripts/validate-configs.sh --static
git diff --check
```

ClickHouse 网关专区还必须运行：

```bash
node scripts/sanitize-clickhouse-gateway-dashboard.mjs
bash scripts/validate-clickhouse-gateway.sh --static
```

多条件值只能由经过测试的构造函数生成 LogsQL，再通过 `${message_filter_expr:raw}` 插入。用户输入不得直接 raw 插值。编辑、添加、删除和切换 AND/OR 不得触发查询；只有 Apply 和 Reset 可以更新 Dashboard 变量。

## 插件发布

使用 `scripts/install-grafana-plugins.sh` 生成新的 release 目录。已存在目录只校验、不覆盖。发布流程必须包含：

1. 精确版本下载到同一父目录的随机暂存目录。
2. `grafana cli plugins ls` 核对版本。
3. 生成并验证 `SHA256SUMS`。
4. 去除写权限后原子改名。
5. 用目标 Grafana 镜像和只读挂载做隔离启动。

迁移已有 Grafana 时，先盘点数据库预加载的历史应用。若必须保留，创建新的兼容 release 并更新不兼容的历史插件；不得原地修改已发布 release。

## 线上变更顺序

1. 只读盘点真实 Compose 所有权、镜像 digest、挂载、插件、字段、资源和健康状态。
2. 一致性备份 Compose、配置、Dashboard、datasource、插件清单和停止后的 SQLite，并生成 SHA-256。
3. 在复制数据、loopback 端口和候选只读插件目录上隔离验证。
4. 用目标机实际 Compose 展开候选配置；注意 CRLF/LF 和旧 Compose 兼容差异。
5. 先测试后生产，只重建 Grafana，并复核镜像、资源、挂载、重启、OOM、插件签名和 datasource health。
6. 使用用户已登录的 Chrome 原标签页验证布局、Apply/Reset、URL 恢复、请求数量和匹配高亮。
7. 页面最终保持最近 15 分钟、零多条件、自动刷新关闭。

失败时立即恢复对应环境最近一次一致性备份。Grafana 13 数据库不得直接交给旧 Grafana 镜像使用。

ClickHouse 失败时不能只切旧镜像。若新版本已写入生产数据目录，必须同时恢复旧版本对应的一致性数据快照。首次启动新 ClickHouse 必须使用第二份数据副本和 loopback 端口隔离验证。

## Git 交付

- 实现、文档、校验和脱敏截图必须在同一个 PR。
- 等待所有 required checks 成功后再合并；禁止强推 `main`。
- Release 只从已合并且重新验证的 `main` 创建。
- 不提交本机临时脚本、缓存、备份、原始截图或服务器凭据。
