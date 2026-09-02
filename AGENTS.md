# VVG Repository Agent Guide

本文件适用于整个仓库。AI Agent 或自动化修改本项目时，必须先读取本文件，再读取任务对应的运行手册。

## 必读顺序

1. `README.md`
2. `docs/ai-agent-operations-guide.md`
3. `docs/vector-victorialogs-latency-runbook.md`
4. `docs/grafana-victorialogs-query-performance-runbook.md`
5. `docs/grafana-victorialogs-log-search-dashboard-guide.md`
6. 即将修改的 Compose、环境变量示例、Dashboard 生成器和校验脚本

## 不可破坏的基线

- 所有镜像和 Grafana 插件必须固定精确版本；禁止 `latest`。
- Grafana 正式启动不得联网安装插件。插件必须先发布到版本化宿主机目录，再只读挂载到 `/var/lib/grafana-plugins`。
- 外置插件目录必须位于 `/var/lib/grafana` 数据挂载之外；同时设置 `GF_PLUGINS_PREINSTALL_DISABLED=true` 和 `GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`。
- 密码、Token、服务器清单、真实内网地址和运行数据不得进入 Git、PR、Release 或截图。
- Dashboard UID `vvg-log-search`、VictoriaLogs datasource UID `victorialogs-ds`、默认 15 分钟、日志明细 500 行和 Query/Multi 变量 `allValue: "*"` 不得无证据修改。
- 测试和生产使用同一查询逻辑、面板代码、颜色和限制；只允许标题、集群显示名、环境标签和默认 namespace 不同。
- 只改获批服务。Grafana 变更不得顺带升级 VictoriaLogs、Vector 或业务服务。

## Dashboard 修改

`scripts/render-vvg-message-filter.mjs` 是 message 多条件面板和紧凑布局的源。不要分别手改面板模板与 Dashboard：

```bash
node scripts/render-vvg-message-filter.mjs
node scripts/validate-vvg-message-filter.mjs
bash scripts/validate-configs.sh --static
git diff --check
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

## Git 交付

- 实现、文档、校验和脱敏截图必须在同一个 PR。
- 等待所有 required checks 成功后再合并；禁止强推 `main`。
- Release 只从已合并且重新验证的 `main` 创建。
- 不提交本机临时脚本、缓存、备份、原始截图或服务器凭据。
