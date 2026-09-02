# VVG Kibana 式 message 条件过滤器设计

> 日期：2026-09-02  
> 状态：已批准  
> 范围：生产与测试 Grafana 日志检索大屏

## 1. 背景

现有大屏已经用集群、namespace、服务、Pod、级别筛选日志，并通过 `_msg:$message` 提供单条件搜索和黄色高亮。新需求只针对日志主体 `message/_msg`：用户需要像 Kibana 一样逐条添加或删除条件，每条条件选择“包含/不包含”，并用一个全局 AND/OR 模式组合。默认没有条件，编辑期间不查询，点击“应用过滤”后统一刷新。

Grafana 原生 Ad hoc filters 能提供动态条件行，但 VictoriaLogs 将它们固定按 AND 应用，无法把同一批条件切换成全局 OR。Custom 多选变量虽能动态添加值，却不符合逐条条件编辑的交互。Business Forms 6.3.5 的运行验证进一步确认每个元素被固定包装为独立 `InlineFieldRow`，无法实现 Kibana 式“操作符 + 输入 + 删除”同一行。因此最终采用签名 Business Text 面板渲染受控行式 UI。

## 2. 目标

- 保留现有基础字段和单条件 message 搜索。
- 动态添加、删除任意数量的 message 条件行。
- 每行仅支持“包含/不包含”，正则留在折叠的高级表达式。
- 全局切换 AND/OR，不支持嵌套分组。
- 默认零条件；输入和编辑期间不触发日志查询。
- 点击“应用过滤”后安全生成 LogsQL，并同步 URL 以支持分享和刷新恢复。
- 生产、测试共享查询逻辑、颜色、限制和表单代码；只派生环境标题、集群标识和默认 namespace。

## 3. 插件选择

使用 `marcusolsson-dynamictext-panel` `6.3.0`：

- Grafana 插件目录签名，当前由 Grafana Labs 维护。
- 依赖 Grafana `>=12.3.0`，发布记录已验证 Grafana 13 / React 19。
- 支持受控 HTML、事件处理、自定义 CSS、`locationService` 和 Dashboard 变量。
- Apache-2.0，无需自建未签名插件。

插件由一次性 Grafana CLI 容器安装到版本化宿主机 release 目录，生产以只读方式挂载，启动不联网下载。Grafana 镜像与插件分别固定版本并由 CI 检查；升级任一方时先在新组合上验证兼容性，不要求因插件变化重建 Grafana 镜像。

## 4. 界面设计

在顶部变量和日志概览之间增加一个全宽、紧凑的 Business Text 面板：

```text
message 条件过滤器                         [AND | OR]

[包含   ] [退款申请                         ] [删除]
[不包含 ] [调试日志                         ] [删除]
[包含   ] [湖南非税                         ] [删除]

[+ 添加条件]                         [重置] [应用过滤]
```

- 全局逻辑使用 Radio/Select，默认 AND。
- 每行包含一个操作符 Select、一个 String Input 和一个删除 Button。
- “添加条件”动态追加一行，软上限 20 行。
- “应用过滤”使用 Submit 按钮；“重置”清空条件并恢复默认。
- 高级 LogsQL 过滤表达式放在可折叠 Section，默认 `*`，只接受过滤器，不接受 pipes。

## 5. Dashboard 状态

新增两个隐藏 Text box 变量：

- `message_filter_expr`：面板生成的 LogsQL，默认 `*`。
- `message_filter_state`：URL-safe JSON，保存逻辑模式、条件行和高级表达式。

四个查询在现有 `_msg:$message` 后追加：

```logsql
${message_filter_expr:raw}
```

Business Text 的 After Render Code 从 `message_filter_state` 恢复条件行，并通过事件委托处理添加、删除、编辑、Apply 和 Reset。Apply 验证、规范化并生成表达式，然后通过 `locationService.partial()` 同时更新两个变量；Grafana 只在这一步刷新面板。Reset 将两者恢复为 `*` 和空状态。

## 6. LogsQL 生成

每个值先移除 NUL 和换行，再转义反斜杠及双引号，始终放入双引号中：

```text
包含    -> _msg:"value"
不包含  -> -_msg:"value"
```

AND：

```logsql
_msg:"退款申请" -_msg:"调试日志" _msg:"湖南非税"
```

OR：

```logsql
(_msg:"退款申请" OR -_msg:"调试日志" OR _msg:"湖南非税")
```

零条件生成 `*`。高级表达式不为空时与表单表达式做 AND。只有固定操作符、固定逻辑和经过引用的值进入普通表达式；用户值永不直接 raw 插值。

## 7. 性能与安全

- 先按 namespace/container/pod/level 流字段收窄，再执行 message 条件。
- 只在点击 Apply/Reset 时更新变量，避免输入过程中反复执行四个查询。
- 明细继续限制 500 行、默认 15 分钟、自动刷新关闭。
- 条件软上限 20，空条件不允许提交；超限显示警告。
- Custom Code 不调用外部 API，不发送日志或条件到第三方。
- 表单状态仅保存在 Dashboard URL，不写数据库或后端服务。
- 高级表达式明确标记为受信任用户功能；快速语法错误可通过 Reset 恢复。

## 8. 验证标准

- 插件版本、签名和 Grafana 13 兼容性通过。
- 默认零条件与版本 6 的查询结果一致。
- 动态添加、删除、Apply、Reset、刷新恢复和复制 URL 全部可用。
- 2、5、10、20 条条件均返回 200；AND/OR 计数关系正确。
- 中文、空格、反斜杠、双引号和换行正确转义。
- 包含/不包含语义正确；匹配词尽可能保持黄色高亮，插件能力限制必须如实记录。
- 无效高级表达式快速失败，Reset 后恢复。
- Grafana 无 OOM/重启/查询 5xx，VictoriaLogs 无新增慢查询或并发触顶。
- Chrome 在桌面页面验证无控件重叠、条件行可读、按钮状态明确。

## 9. 发布与回滚

先生成包含两个固定插件的候选 release 目录，在测试环境与固定 Grafana 镜像隔离验证，再只重建测试 Grafana 并验证 Dashboard。测试通过后，把同一插件包和 JSON 发布生产。

每个环境更新前备份镜像引用、Compose、插件目录路径、Dashboard 和 Grafana 数据库。回滚时恢复版本 6 Dashboard、旧插件 release 路径和旧 Grafana 镜像引用；不修改 VictoriaLogs、Vector 或业务日志数据。
