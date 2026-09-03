# Grafana x VictoriaLogs 生产日志检索大屏配置与导入指南

本文档说明如何复用、导入、验证和维护仓库中的 `VVG 生产日志检索大屏`。目标是让研发、运维和后续 AI agent 在不了解本次现场上下文的情况下，也能安全地完成部署与修改。

## 1. 适用范围

- Grafana `13.2.0`。
- VictoriaLogs Grafana 数据源插件 `0.31.0`。
- Business Text 面板插件 `6.3.0`。
- 数据源类型 `victoriametrics-logs-datasource`。
- 默认数据源 UID `victorialogs-ds`。
- Kubernetes/CCE 容器日志，日志字段满足本文的数据契约。

Dashboard 源文件：

```text
docker-compose/grafana/dashboards/vvg-log-search.json
```

## 2. 设计目标

该大屏不是容量监控或业务 KPI 大屏，而是面向研发现场排障的日志检索工作台：

1. 新打开时直接查询最近 15 分钟、`jwxt-prod` 命名空间。
2. 不需要编辑 LogsQL，即可选择命名空间、微服务、Pod 和级别。
3. 可以在日志正文中进行单条件搜索，也可以动态组合多个“包含/不包含”条件。
4. 多条件编辑期间不查询，只有点击“应用过滤”才统一刷新。
5. 日志概览和趋势合并为一行，左侧趋势图、右侧双统计，可整体折叠以保留日志阅读区域。
6. 自动刷新默认关闭，避免多人打开时持续扫描高流量日志。
7. 所有级别颜色固定与 Grafana Explore 一致，不随序列顺序变化。
8. JSON 是配置源，支持 Git 审计、回滚和自动校验。

## 3. 日志数据契约

### 3.1 必需字段

| 字段 | 用途 | 建议类型 | 是否建议设为流字段 |
| --- | --- | --- | --- |
| `namespace` | Kubernetes 命名空间筛选 | string | 是 |
| `container` | 微服务名称筛选 | string | 是 |
| `pod` | Pod 实例筛选 | string | 是 |
| `level` | 日志级别筛选和趋势分组 | string | 是 |
| `message` | 原始日志内容和模糊搜索 | string | 否 |

当前生产环境还包含 `job` 流字段，但大屏不依赖它。

### 3.2 可选字段

| 字段 | 用途 | 约束 |
| --- | --- | --- |
| `cluster` | 多集群选择 | 必须是稳定的逻辑集群标识，不能使用节点名、Pod IP 或 ELB VIP 代替 |

当前生产日志没有 `cluster` 字段，因此大屏使用单值控件 `生产 CCE` 作为兼容入口，但查询不会使用这个占位值。

### 3.3 检查实际流字段

在 VictoriaLogs 主机执行只读查询：

```bash
curl -fsS http://127.0.0.1:9428/select/logsql/stream_field_names \
  -d 'query=*' \
  -d 'start=24h' \
  -d 'end=now'

curl -fsS http://127.0.0.1:9428/select/logsql/stream_field_values \
  -d 'query=*' \
  -d 'start=24h' \
  -d 'end=now' \
  -d 'field=namespace'
```

不要仅根据字段名称猜测集群、节点、VIP 或 Pod 的含义。

## 4. 大屏结构

### 4.1 顶部变量

| 显示名称 | 变量名 | 类型 | 默认值 | 数据来源 |
| --- | --- | --- | --- | --- |
| 集群 | `cluster` | Custom | `生产 CCE` | 单值占位 |
| 命名空间 | `namespace` | Query/Multi | `jwxt-prod` | `namespace` 字段值 |
| 服务 | `service` | Query/Multi | All | `container` 字段值 |
| Pod | `pod` | Query/Multi | All | `pod` 字段值 |
| 级别 | `level` | Query/Multi | All | `level` 字段值 |
| message | `_msg` | Text box | `*` | 用户输入，使用模糊搜索 |
| message 多条件表达式 | `message_filter_expr` | 隐藏 Text box | `*` | Business Text 生成 |
| message 表单状态 | `message_filter_state` | 隐藏 Text box | 空状态 | URL-safe JSON |

后续变量依赖前面的变量：命名空间变化后，微服务列表会刷新；微服务变化后，Pod 和级别列表会刷新。

`message_filter_expr` 和 `message_filter_state` 不显示在变量栏。前者只保存经过引用和校验的 LogsQL，后者保存 AND/OR、条件行和高级表达式；两者随 URL 同步，因此刷新页面或复制完整链接后可恢复已应用状态。

所有 Query/Multi 变量都显式设置 `allValue: "*"`。否则 Grafana 可能把 All 展开成全部服务和全部 Pod 的长列表，导致请求体膨胀并增加插件与 Grafana 的处理负担。正确展开结果应类似：

```logsql
container:in(*) pod:in(*) level:in(*)
```

### 4.2 可折叠区域

- `日志概览与趋势`：左侧包含按级别堆叠趋势图，右侧上下包含匹配日志数和错误/严重日志数。
- `日志明细`：作为独立行边界，保护日志面板不被上一个折叠行一起隐藏。

Grafana 的展开行会包含它后面的面板，直到遇到下一个 `row` 面板。因此不能删除 `日志明细` 行边界，否则折叠 `日志概览与趋势` 时可能连日志明细一起隐藏。

### 4.3 紧凑布局

- 左侧趋势图宽度为 `19/24`，高度为 8；右侧两个统计面板宽度为 `5/24`，高度各 4。
- 趋势图复用 Explore `Logs volume` 的连续时间桶和底部图例；最多约 100 个桶，`barWidthFactor: 0.6` 让柱体占每个桶位宽度的 60%，在保持趋势连续性的同时留出清晰间隔。
- 数字字号固定为 28。
- 统计面板关闭小型背景趋势图。
- 日志明细保留 20 个网格单位高度。

### 4.4 Explore 级别颜色

| 级别 | 颜色 |
| --- | --- |
| `critical` | `#705DA0` |
| `error` | `#E24D42` |
| `warning` / `warn` | `#EAB839` |
| `info` | `#7EB26D` |
| `debug` | `#1F78C1` |
| `trace` | `#6ED0E0` |
| `unknown` | `#8E8E8E` |

生产日志的字段值是 `warn`，Dashboard 通过 field override 将图例显示为 `warning`。

## 5. LogsQL 查询

所有面板复用以下基础条件：

```logsql
namespace:=$namespace container:=$service pod:=$pod level:=$level _msg:$message ${message_filter_expr:raw}
```

### 5.1 匹配日志数

```logsql
namespace:=$namespace container:=$service pod:=$pod level:=$level
_msg:$message
${message_filter_expr:raw}
| stats count() as matching_logs
```

### 5.2 错误/严重日志数

```logsql
namespace:=$namespace container:=$service pod:=$pod level:=$level level:in("error","critical")
_msg:$message
${message_filter_expr:raw}
| stats count() as error_logs
```

### 5.3 按级别趋势

趋势面板使用 VictoriaLogs datasource 的 `hits` / `logsVolume` 查询类型，并按 `level` 字段分组；这是 Grafana Explore `Logs volume` 使用的同一条数据路径。面板把最大数据点固定为 100，由 `$__interval` 随时间范围自动计算桶宽，并保留空桶为零，因此 15 分钟、3 小时或更长的可选范围都能显示清晰且连续的柱形。

```logsql
namespace:=$namespace container:=$service pod:=$pod level:=$level
_msg:$message
${message_filter_expr:raw}
```

不要把该面板改回 `statsRange | stats by (level) count()`。该形式只返回有命中的稀疏时间点；在 3 小时范围和宽面板中曾自动降到 5 秒步长，单柱小于一个屏幕像素，虽然图例总数正确但图形区域近似空白。

### 5.4 message 为什么使用 word filter

`message` 是 Grafana Text box 变量，通过官方推荐的 `_msg:$message` word filter 使用。默认值 `*` 表示不限制日志正文；插件会对变量值进行引用和转义，并把搜索词写入 Grafana 的 `searchWords` 元数据，使 Logs 面板高亮匹配内容。

不要使用 `message:~$message`，也不要直接写 `| $message`。前者不能稳定生成高亮元数据并会让 `*` 变成非法正则；后者会把未加引号的中文直接放进 LogsQL。需要高级正则时，在 Explore 中编写明确的 LogsQL，例如 `_msg:~"request-[0-9]+"`。

### 5.5 多条件 message 过滤器

点击“添加条件”后，每行选择“包含”或“不包含”并输入内容；全局选择“全部满足（AND）”或“任一满足（OR）”。添加、删除和编辑只改变浏览器本地表单，不执行查询；点击“应用过滤”才生成表达式并更新 URL。对于 `now-15m` 到 `now` 等标准滑动窗口，应用前会把当前时间范围原地推进到最新时刻，再由筛选变量变化统一触发一轮查询，因此无需再点击顶部 Refresh；绝对时间范围保持原样，便于回看历史。零条件生成 `*`，普通条件软上限为 20。

普通值会移除 NUL 和换行，转义反斜杠及双引号，并始终放入双引号。示例：

```logsql
_msg:"湖南非税" -_msg:"调试日志"
(_msg:"退款申请" OR -_msg:"调试日志")
```

高级 LogsQL 区域默认折叠，只允许 filter，不允许 `| stats`、`| sort` 等管道。它属于受信任运维入口；语法错误应快速返回，使用“重置”可恢复零条件。

## 6. 导入前检查

1. Grafana 健康检查通过：

   ```bash
   curl -fsS http://127.0.0.1:3000/api/health
   ```

2. VictoriaLogs 健康检查通过：

   ```bash
   curl -fsS http://VICTORIALOGS_HOST:9428/health
   ```

3. Grafana 已安装精确版本的插件：

   ```bash
   grafana cli plugins ls
   ```

4. 数据源 UID 是 `victorialogs-ds`。如果目标环境使用其他 UID，必须先在 JSON 副本中替换全部 `victorialogs-ds`。
5. 实际字段名与第 3 节一致。
6. 目标 Grafana 账号具有 Dashboard 导入或 Provisioning 权限。

## 7. 导入方式一：文件 Provisioning（推荐）

文件 Provisioning 适合生产环境和 GitOps，是本仓库的默认方式。

### 7.1 Provider 配置

```yaml
apiVersion: 1

providers:
  - name: VVG-Dashboards
    orgId: 1
    folder: VVG Logs
    type: file
    disableDeletion: false
    editable: true
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
```

注意：provider YAML 和 dashboard JSON 可以位于同一个挂载目录，但 Grafana 只会把 JSON 作为 Dashboard 读取。

### 7.2 Compose 挂载

```yaml
volumes:
  - ./dashboards:/etc/grafana/provisioning/dashboards:ro
```

### 7.3 首次部署

```bash
python3 -m json.tool dashboards/vvg-log-search.json >/dev/null
install -m 0644 dashboards/vvg-log-search.json \
  /data/grafana/dashboards/vvg-log-search.json
```

等待 `updateIntervalSeconds` 后打开：

```text
/d/vvg-log-search/vvg-production-log-search
```

正常情况下不需要重启 Grafana。

### 7.4 生产更新

先上传临时文件，验证后再原子替换：

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
install -d -m 0700 /data/grafana/backups
cp -a /data/grafana/dashboards/vvg-log-search.json \
  "/data/grafana/backups/vvg-log-search-${STAMP}.json"

python3 -m json.tool \
  /data/grafana/dashboards/.vvg-log-search.json.upload >/dev/null
chmod 0644 /data/grafana/dashboards/.vvg-log-search.json.upload
mv -f /data/grafana/dashboards/.vvg-log-search.json.upload \
  /data/grafana/dashboards/vvg-log-search.json
```

不要直接在生产目标文件上进行半写入式编辑。

### 7.5 配置源约束

即使 provider 允许 UI 更新，也应以 Git 中的 JSON 为最终配置源。UI 修改验证有效后，必须同步回 JSON，否则下一次 Provisioning 更新会造成漂移。

## 8. 导入方式二：Grafana UI

适合测试环境或一次性验证：

1. 进入 **Dashboards -> New -> Import**。
2. 上传 `vvg-log-search.json`。
3. 选择目标 Folder。
4. 确认数据源 UID 已存在。
5. 点击 Import。
6. 使用第 10 节进行验收。

如果数据源 UID 不同，可在导入副本中替换：

```powershell
$source = Get-Content -Raw .\vvg-log-search.json
$source.Replace('"uid": "victorialogs-ds"', '"uid": "YOUR_DATASOURCE_UID"') |
  Set-Content -Encoding utf8 .\vvg-log-search.import.json
```

不要把修改后的环境专用 UID 直接提交回本仓库，除非仓库的数据源基线也同步变更。

## 9. 导入方式三：Grafana HTTP API

适合受控自动化。使用最小权限 Service Account Token，不要在命令历史、文档或 Git 中写入 Token。

```bash
export GRAFANA_URL='https://grafana.example.com'
export GRAFANA_TOKEN='REDACTED'

jq -n \
  --slurpfile dashboard docker-compose/grafana/dashboards/vvg-log-search.json \
  '{dashboard: $dashboard[0], folderUid: "", overwrite: true}' \
  | curl -fsS \
      -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data-binary @- \
      "${GRAFANA_URL}/api/dashboards/db"
```

生产环境优先使用文件 Provisioning；API 导入不能代替仓库提交和评审。

## 10. 导入后验收

### 10.1 干净页面默认值

必须使用新的浏览器标签页或不带旧变量参数的 URL 验证：

- 时间：Last 15 minutes。
- 命名空间：`jwxt-prod`。
- 微服务、Pod、级别：All。
- message：`*`。
- message 多条件：零条件、AND、高级表达式 `*`。
- 自动刷新：Off。

旧书签、旧标签页和 URL 中的 `var-*`、`from`、`to` 参数会覆盖 Dashboard 默认值。

### 10.2 功能验证

1. 所有四个查询返回数据，无 `No data` 或 LogsQL 解析错误。
2. 输入一个已知 message 片段，匹配数量下降且日志明细全部命中。
3. 添加、删除和编辑多条件时，四个日志查询不应启动；点击“应用过滤”后才统一刷新。相对时间范围下连续两次应用时，请求中的 `from`/`to` 必须向前推进，且每次仍只有四个面板各查询一次。
4. 验证包含/不包含、AND/OR、2/5/10/20 条、中文、空格、引号、反斜杠和刷新恢复。
5. 21 条被前端拒绝，高级表达式含管道时显示错误且不更新查询。
6. 选择一个微服务，统计、趋势和明细同时收窄。
7. 选择一个 Pod，Pod 列表只来自已选命名空间和微服务。
8. 折叠 `日志概览与趋势`，两个统计和趋势图一起隐藏，但 `日志明细` 保持可见。
9. 展开概览与趋势，级别颜色与第 4.4 节一致。
10. Grafana 容器保持 `running/healthy`，`RestartCount=0`。

当前单轮刷新兼容矩阵：Grafana 12.4.4 / 13.2.0，Business Text 6.3.0。两套环境在标准最近 15 分钟范围中连续 Apply 均为每次 4 个请求，URL 保持 `from=now-15m&to=now`。版本升级后此项必须作为阻断性回归测试，而不是只检查页面能否打开。

### 10.3 直接验证 LogsQL

```bash
curl -fsS http://VICTORIALOGS_HOST:9428/select/logsql/query \
  --data-urlencode 'query=namespace:in("jwxt-prod") container:in(*) pod:in(*) level:in(*) _msg:*' \
  -d 'start=15m' \
  -d 'end=now' \
  -d 'limit=1'

curl -fsS http://VICTORIALOGS_HOST:9428/select/logsql/stats_query \
  --data-urlencode 'query=namespace:in("jwxt-prod") container:in(*) pod:in(*) level:in(*) _msg:* | stats count() as matching_logs' \
  -d 'start=15m' \
  -d 'end=now'

curl -fsS http://VICTORIALOGS_HOST:9428/select/logsql/stats_query_range \
  --data-urlencode 'query=namespace:in("jwxt-prod") container:in(*) pod:in(*) level:in(*) _msg:* | stats by (level) count() as logs' \
  -d 'start=15m' \
  -d 'end=now' \
  -d 'step=1m'
```

## 11. 多集群扩展

### 11.1 先补采集字段

在 Vector 发往 VictoriaLogs 时写入稳定的 `cluster` 字段，并把它加入 `_stream_fields`。示例概念配置：

```yaml
transforms:
  add_cluster:
    type: remap
    inputs: [kubernetes_logs]
    source: |
      .cluster = "prod-cce-north-1"
```

写入端应包含：

```text
_stream_fields=cluster,namespace,container,pod,level
```

### 11.2 再改 Dashboard

1. 把 `cluster` 从 Custom 变量改为 VictoriaLogs Query 变量。
2. 查询字段设为 `cluster`，允许多选和 All。
3. `namespace` 变量查询增加 `cluster:=$cluster`。
4. 所有面板基础条件最前面增加 `cluster:=$cluster`。
5. 使用两个真实集群验证变量联动和日志隔离。

只有一个真实集群时，不要为了出现下拉框而伪造多个值。

## 12. 性能基线

- 默认时间窗保持 15 分钟。
- 自动刷新保持关闭，由用户按需开启。
- 单次日志明细限制 500 行；需要更多上下文时先选择微服务或 Pod 缩小范围。
- Multi 变量的 All 必须使用自定义值 `*`，禁止枚举全部服务和 Pod。
- 优先按流字段缩小范围，再执行 message word filter；高级正则放到 Explore。
- 多条件只在“应用过滤”时刷新；不要把 `elementValueChanged` 改成自动更新 Dashboard 变量。
- 标准滑动窗口不要在 `locationService.partial()` 后无条件调用 `context.grafana.refresh()`：这会产生两轮查询。当前实现先原地推进 Business Text 提供的 `timeRange`，再在原表达式与等价括号表达式之间切换，保证被查询引用的 `message_filter_expr` 每次都发生变化，因此只发起一轮最新时间查询。VictoriaLogs 已验证 `filter` 与 `(filter)`、`*` 与 `(*)` 语义等价。带日期取整等非标准相对范围无法安全平移，才使用 `context.grafana.refresh()` 兜底；绝对时间范围不会被改写。
- 普通 message 条件最多 20 条，超出时先缩小 namespace、service 或 Pod 范围。
- 不要把默认范围改为 1 小时或 24 小时。
- 不要因为 UI 转圈就直接扩大 VictoriaLogs 并发；先区分浏览器取消、插件错误、反向代理和后端执行时间。

## 13. 安全要求

1. 日志中的 Token、Cookie、手机号、身份证、地址等信息必须在 Vector 或应用输出阶段脱敏。
2. Dashboard 隐藏字段不等于删除敏感数据，不能作为脱敏方案。
3. Grafana Viewer 权限仍然可以读取日志内容，应按最小权限管理用户和 Folder。
4. 不要把 Grafana Token、管理员密码、VictoriaLogs 凭据或服务器登录信息写入 JSON、文档、PR 或 AI 对话。
5. 下载或分享日志前应再次检查敏感信息。

## 14. 常见故障

### 14.1 所有面板显示 No data

依次检查：

1. 面板状态提示中的完整 LogsQL 错误。
2. `message` 是否为 `*`，而不是旧版 `.*` 或空值。
3. 数据源 UID 是否存在。
4. URL 是否带有旧的 `var-message=*`。
5. 变量是否展开成过长或互相冲突的 `in(...)` 条件。
6. URL 中的 `var-message_filter_expr` 是否为合法 LogsQL；不确定时点击多条件面板“重置”。

如果 All 被展开成几十个服务或 Pod，确认对应变量的 `allValue` 仍为 `*`。

### 14.2 折叠概览与趋势后日志也消失

确认 `日志概览与趋势` 和日志面板之间存在 `日志明细` row 面板。Grafana 使用下一个 row 作为折叠边界。

### 14.3 颜色与 Explore 不一致

确认趋势面板仍有按字段名的 fixed color overrides，不要改回 `palette-classic` 自动分配。

### 14.4 Provisioning 文件更新但页面未变化

1. 等待 provider 扫描周期。
2. 检查远端文件校验和和权限。
3. 使用新标签页打开不带旧变量参数的 URL。
4. 检查 Grafana 日志中的 provisioning 错误。
5. 必要时递增 Dashboard `version`。

### 14.5 Live 实时模式不可用

普通 Dashboard 查询不依赖 Grafana Live。如果 `/api/live/ws` 返回 400，检查反向代理是否正确转发 WebSocket 的 `Upgrade` 和 `Connection` 头。不要把这个问题误判为 VictoriaLogs 查询失败。

## 15. 回滚

### 15.1 Provisioning 回滚

```bash
cp -a /data/grafana/backups/vvg-log-search-YYYYMMDD-HHMMSS.json \
  /data/grafana/dashboards/.vvg-log-search.json.rollback
python3 -m json.tool \
  /data/grafana/dashboards/.vvg-log-search.json.rollback >/dev/null
chmod 0644 /data/grafana/dashboards/.vvg-log-search.json.rollback
mv -f /data/grafana/dashboards/.vvg-log-search.json.rollback \
  /data/grafana/dashboards/vvg-log-search.json
```

等待 provider 自动加载并重复第 10 节验收。

Business Text 版本或面板代码导致页面不可用时，必须同时恢复旧 Dashboard JSON 和旧插件 release 路径；只回滚 JSON 会留下无用插件，只回滚插件目录会使新面板显示插件缺失。恢复后核对镜像 ID、两个插件版本、Dashboard version 和隐藏变量均回到备份状态。

### 15.2 Git 回滚

通过新的 PR 回滚对应提交。不要强推 `main`，不要只在生产服务器改文件而不修复仓库源文件。

## 16. 后续 AI agent 执行约束

AI agent 修改本大屏时必须遵循以下顺序：

1. 读取本指南、Dashboard JSON、数据源 provisioning 和静态校验脚本。
2. 先只读检查真实字段、流字段、插件版本、数据源 UID 和生产拓扑。
3. 不从节点名、VIP、Pod 名推断集群身份。
4. 只修改 Dashboard、相关说明和校验，不顺带升级 Grafana、插件、VictoriaLogs 或 Vector。
5. 在本地解析 JSON，并运行 `bash scripts/validate-configs.sh --static`。
6. 对所有 LogsQL 类型分别验证：raw、stats、stats range。
7. 生产更新前创建有界备份，使用临时文件和原子替换。
8. 使用干净浏览器页面验证默认值、筛选、message 搜索、折叠和颜色。
9. 验证 Grafana 健康状态和重启次数。
10. 把最终 JSON、文档和校验放在同一个 PR 中，等待 CI 通过后再合并。

禁止事项：

- 禁止把生产凭据写入仓库或 PR。
- 禁止使用 `latest`、未固定插件版本或运行时在线安装插件。
- 禁止删除既有 Dashboard 或覆盖其他 Folder。
- 禁止跳过备份直接编辑生产文件。
- 禁止用 UI 临时修改代替 Git 中的 JSON。
- 禁止在未经证据验证时扩大查询并发或默认时间窗。

## 17. 仓库验证

提交前执行：

```bash
bash scripts/validate-configs.sh --static
node scripts/validate-vvg-message-filter.mjs
git diff --check
```

校验覆盖：

- JSON 语法。
- Dashboard 稳定 UID。
- 最近 15 分钟默认范围。
- `jwxt-prod` 默认命名空间。
- namespace/container/message 查询能力。
- message 的 `*` 默认值和 word filter 查询。
- Business Text `6.3.0`、两个隐藏变量和四条共享过滤表达式。
- 表达式生成器的包含/不包含、AND/OR、转义、20 条边界和高级管道拒绝。
- 四个 Query/Multi 变量的 `allValue: "*"`。
- 两个紧凑折叠行边界。
- 紧凑统计面板。
- Explore 固定颜色。

完整运行时验证见 [Grafana/VictoriaLogs 查询性能与升级运行手册](grafana-victorialogs-query-performance-runbook.md)。
