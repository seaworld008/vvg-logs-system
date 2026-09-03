# VVG AI Agent 配置、升级与验收指南

本文面向后续 AI Agent 和运维自动化。目标是在没有本次会话上下文的情况下，也能安全、快速地部署或维护 Vector -> VictoriaLogs -> Grafana 日志系统。

## 1. 快速定位

### VVG 主系统

| 任务 | 首要文件 |
| --- | --- |
| Grafana 与外置插件 | `docker-compose/grafana/README.md`、`scripts/install-grafana-plugins.sh` |
| 日志检索 Dashboard | `scripts/render-vvg-message-filter.mjs`、`docker-compose/grafana/dashboards/vvg-log-search.json` |
| 查询慢或页面转圈 | `docs/grafana-victorialogs-query-performance-runbook.md` |
| Vector 延迟或丢日志 | `docs/vector-victorialogs-latency-runbook.md` |
| 字段、导入、回滚 | `docs/grafana-victorialogs-log-search-dashboard-guide.md` |
| 全仓库约束 | `AGENTS.md`、`scripts/validate-configs.sh` |

### 附加 Gateway 方案

| 任务 | 首要文件 |
| --- | --- |
| Gateway 日志写入 ClickHouse | `clickhouse-gateway/README.md`、`docs/vector-clickhouse-gateway-runbook.md` |
| KubeDoor Gateway Dashboard / GeoIP | `scripts/sanitize-clickhouse-gateway-dashboard.mjs`、`clickhouse-gateway/vector/geoip/NOTICE.md` |

## 2. 先判断任务边界

- 只改 Dashboard：不要重建 Grafana，不要改 VictoriaLogs 或 Vector。
- 只升级插件：创建新的外置 release，Grafana 镜像不变。
- 只升级 Grafana：先用新镜像挂载现有插件 release 做兼容测试。
- 采集异常：先检查 CRI、真实日志路径、Vector 指标和 VictoriaLogs 写入，不要从 Grafana 查询现象反推采集故障。
- 查询异常：先分离浏览器、Grafana/plugin、反向代理和 VictoriaLogs 后端耗时，不要直接扩大并发或超时。
- Gateway ClickHouse 链路：只改 `vector-clickhouse-gateway` 和其所属 ClickHouse；不要顺带升级现有 Grafana、VictoriaLogs 或应用服务。

### ClickHouse 网关链路特别门禁

- 先用 Compose labels、working directory 和 mounts 确认 ClickHouse 所有权，不能按镜像名判断。
- 最新版本必须在执行时从官方稳定/LTS release 解析，并固定精确 patch；镜像先进入私库，正式启动不得联网拉取。
- 首次新版本启动使用第二份一致性数据副本和 loopback 端口；除了旧数据查询，还必须插入一条与 Vector 相同编码的事件。
- `DateTime64(3)` 使用 RFC3339 字符串。毫秒整数在 ClickHouse 版本间可能产生不同解释，异常分区可能被 TTL 立即删除。
- ClickHouse 120 秒异步写入等待要求 Vector request timeout 大于 120 秒；当前基线 180 秒且不限制 retry attempts。
- 跨 Vector 版本不要复制活动 `disk_v2` buffer。只在 sink 批次排空后迁移 checksum 一致的 checkpoint。
- system log 清理只针对 DDL 明确标注可安全清理的 `system` 表，并且必须先有一致性备份；业务表 TTL、ORDER BY、MV 和 projection 不随镜像升级修改。

## 3. 外置插件最佳实践

插件与 Grafana 镜像使用独立版本：

```text
/data/grafana/plugins/releases/
  grafana13.2.0-vl0.31.0-text6.3.0/
    victoriametrics-logs-datasource/
    marcusolsson-dynamictext-panel/
    BUNDLE-MANIFEST
    SHA256SUMS
```

正式容器只读挂载：

```yaml
volumes:
  - ${GRAFANA_PLUGINS_DIR}:/var/lib/grafana-plugins:ro
environment:
  - GF_PATHS_PLUGINS=/var/lib/grafana-plugins
  - GF_PLUGINS_PREINSTALL_DISABLED=true
  - GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false
```

执行：

```bash
cd docker-compose/grafana
cp env.example .env
# 设置正式 URL、密码、数据目录和固定镜像
sudo bash ../../scripts/install-grafana-plugins.sh .env
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d
```

不要在正式 Compose 中配置 `GF_INSTALL_PLUGINS`、`GF_PLUGINS_PREINSTALL` 或 `GF_PLUGINS_PREINSTALL_SYNC`。

### 已有 Grafana 的兼容迁移

已有 SQLite 可能记录预加载应用。切换为精简只读插件包前：

1. 读取当前 `grafana cli plugins ls` 和浏览器控制台。
2. 隔离启动时确认没有 `Failed to preload plugin`。
3. 必须保留的历史插件复制到新的兼容 release，不原地修改基础 release。
4. 旧插件若与 Grafana 13 / React 19 不兼容，只升级该插件到已验证精确版本。
5. 把最终同一 release 传到测试和生产并比较归档 SHA-256。

Grafana 13 只有一个自定义插件路径和一个镜像内 bundled 路径，不能用多个宿主机目录拼接代替兼容 release。

## 4. Dashboard 生成与派生

生产 Dashboard 是仓库源，测试版本只能派生以下字段：

- 标题；
- `tags` 中的环境标识；
- 集群显示值；
- 默认 namespace。

修改面板时：

```bash
node scripts/render-vvg-message-filter.mjs
node scripts/validate-vvg-message-filter.mjs
```

当前 message 过滤器使用 Business Text 6.3.0。Business Forms 6.3.5 已实测不适合该交互，因为每个表单元素固定占一个 `InlineFieldRow`，无法实现操作符、输入框和删除按钮同一行。

“应用过滤时刷新到最新相对时间”的单轮查询实现已在 Grafana 12.4.4 和 13.2.0、Business Text 6.3.0 上通过浏览器请求级验证。兼容结论仅覆盖这组版本；升级任一组件后，必须重新验证标准 `now-N` 到 `now` 范围每次 Apply/Reset 恰好产生 4 个 `/api/ds/query` 请求，且第二次 Apply 的 `to` 大于第一次。

### 多条件数据流

```text
浏览器本地编辑
  -> 不查询
  -> Apply
     -> 校验 0..20 条
     -> 引用和转义
     -> message_filter_expr
     -> message_filter_state (URL-safe UTF-8)
     -> 4 个 Dashboard 面板刷新
```

包含生成 `_msg:"value"`，不包含生成 `-_msg:"value"`。AND 用空格连接；OR 用括号和 ` OR ` 连接。高级表达式只允许 LogsQL filter，禁止管道、换行和 NUL。

## 5. 变更前备份

必须停止 Grafana 后复制 SQLite：

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/data/grafana/backups/grafana-${STAMP}"
install -d -m 0700 "${BACKUP}"
docker compose stop -t 60 grafana
cp -a docker-compose.yaml dashboards datasources grafana-data "${BACKUP}/"
docker compose start grafana
cd "${BACKUP}"
sha256sum docker-compose.yaml dashboards/vvg-log-search.json \
  datasources/victorialogs.yaml grafana-data/grafana.db > checksums.sha256
sha256sum -c checksums.sha256
```

包含密码的 Compose 或 `.env` 必须保持 `0600`，备份目录保持 `0700`。不要 `source .env`；密码可能包含 shell 特殊字符，只解析所需键。

## 6. 隔离验证

使用一致性备份的数据副本和 loopback 端口：

- 复制 `grafana-data`，不能挂正式目录；
- 候选插件 release 只读挂载；
- 候选 Dashboard 和 datasource 只读挂载；
- 绑定 `127.0.0.1:13001`；
- 复用目标 Grafana 精确镜像；
- 验证 migration、`/api/health`、plugin settings、datasource health 和 Dashboard API；
- 扫描 panic、fatal、migration failed、invalid signature、read-only file system。

目标主机可能没有 Python、Node 或新版 Compose。候选 JSON 先在仓库解析，再比较远端 SHA；Compose 必须用目标机自己的命令展开。

## 7. 正式切换与回滚

切换只重建 Grafana：

```bash
docker compose -f candidate.yaml config --quiet
docker compose stop -t 60 grafana
mv candidate.yaml docker-compose.yaml
mv dashboards/.vvg-log-search.candidate.json dashboards/vvg-log-search.json
docker compose up -d --no-deps --force-recreate grafana
```

旧 `docker-compose 1.25.x` 不会保留仓库中的现代资源字段时，重建后重新执行并核对 `docker update`。现代 Compose 应保留原来的 image digest、CPU、memory、memory-swap 和 PID 配置。

失败时恢复最近备份的 Compose 和 Dashboard 并重建。若回退 Grafana 主版本，同时恢复对应 SQLite 数据目录。

## 8. 浏览器验收矩阵

使用用户已登录的 Chrome 原标签页：

1. 桌面宽度下顶部变量保持一行，窄屏允许响应式换行。
2. message 条件行为“包含/不包含 + 输入 + 删除”同一行。
3. 添加、输入、删除、AND/OR 切换产生 0 个 `/api/ds/query`。
4. Apply 和 Reset 各触发 4 个日志面板请求。
5. 2 条 AND 结果不大于对应 OR；不包含生成负过滤。
6. 刷新和复制 URL 后恢复条件。
7. 已知命中词在日志明细中显示黄色高亮。
8. 5 条条件保持行式布局并在面板内滚动；20 条边界由自动测试和 UI共同约束。
9. 浏览器控制台无插件预加载或运行错误。
10. 3 小时范围的日志趋势使用 `hits` / `logsVolume`、约 100 个连续时间桶和 `barWidthFactor: 0.6`，柱间留白清晰，底部图例总数与统计面板一致。
11. 最终恢复最近 15 分钟、零条件、自动刷新关闭。

## 9. 服务端验收

- Grafana `running/healthy`、`RestartCount=0`、`OOMKilled=false`。
- 镜像 digest 和资源限制与切换前一致。
- 插件和 provisioning 目录只读，插件版本及 `SHA256SUMS` 正确。
- datasource health 为 `OK`，Dashboard 文件 SHA 与仓库派生版本一致。
- Grafana 最近窗口没有严重错误。
- VictoriaLogs `limit_reached_total`、`limit_timeout_total` 不增长；慢查询计数必须记录切换前后增量，不能只看累计值。

## 10. 已验证的故障经验

- Compose 是 CRLF 时，基于 LF 的精确字符串替换会静默失效。先规范换行，再解析展开结果中的卷 source/target/read-only。
- 只读插件目录必须禁用 Grafana 默认预安装和自动更新，否则后台任务会报只读文件系统。
- HTTP 200 的插件 `module.js` 仍可能因 React/Grafana 版本不兼容而执行失败；必须看 Chrome 控制台。
- Grafana API 返回的 Dashboard `version` 是数据库修订计数，不等同于源 JSON 的 `version`。
- Business Text 的“应用过滤”在标准 `now-N` 到 `now` 滑动窗口中，先原地推进 `context.grafana.timeRange`，再让 `message_filter_expr` 在原表达式和等价括号表达式之间切换，以保证单次变量刷新。不要在这条路径追加 `context.grafana.refresh()`，否则四个日志面板会产生两轮查询。带取整的相对时间使用官方刷新兜底；绝对时间范围保持不变。Grafana 或 Business Text 升级后必须重新做请求数量、时间戳和括号 LogsQL 验收。
- 趋势图图例有正确总数但绘图区近似空白时，先检查请求模型和时间桶，不要误判为无日志。`statsRange` 配合宽面板可能按数秒返回数百个仅含非零值的稀疏点，柱宽低于一个像素；Dashboard 应复用 Explore 的 `hits` / `logsVolume`、`fields: ["level"]` 和 `maxDataPoints: 100`，得到约 100 个包含零值的连续桶。
- 主动停止 Grafana 时可能记录一次 `job cleanup controller failed` / `context canceled`。先把该行时间与容器新的 `StartedAt` 比较；若它发生在启动前，且启动后严重错误为零、健康和 datasource 均正常，应归类为关停噪声，不要据此回滚。
- 扫描 Grafana 严重日志时要把 `level=(error|critical)` 锚定为独立 logfmt 字段。裸搜索 `level=error` 会误命中 Dashboard URL 中的 `var-level=error`，把正常的 info 请求误报成错误。
- 远端缺少 Python 不代表 JSON 无法验证；本地解析后比较 SHA 即可。
- 浏览器中的“转圈”不等于 VictoriaLogs 并发不足；先看请求状态和后端耗时。

## 11. 提交与发布

```bash
node scripts/render-vvg-message-filter.mjs
node scripts/validate-vvg-message-filter.mjs
node scripts/sanitize-clickhouse-gateway-dashboard.mjs
node scripts/validate-clickhouse-gateway.mjs
bash -n scripts/install-grafana-plugins.sh
bash -n scripts/validate-configs.sh
bash scripts/validate-configs.sh --static
git diff --check
```

运行时 CI通过后创建 PR。合并 `main` 后在合并提交上重跑静态校验，再创建带说明和升级/回滚链接的 Release。
