# VVG 生产基线加固设计

> 日期：2026-09-01  
> 状态：已批准  
> 范围：Vector -> VictoriaLogs -> Grafana

## 1. 背景

近期生产排查和升级暴露了四类可复用问题：

1. Grafana Explore 默认查询一小时全量日志，用户打开页面时会立即触发较大的日志和直方图查询。
2. Grafana 启动时在线更新未固定版本的插件，下载卡住时会先移除旧插件，导致服务长时间无法监听。
3. 查询转圈不一定是后端并发不足。现场请求主要是浏览器主动取消形成的 `499/context canceled`，并伴随错误 LogsQL；VictoriaLogs 并发上限没有触顶。
4. Docker Compose、Kubernetes 和文档中的 Vector/VictoriaLogs 推荐值存在漂移，仓库缺少统一的自动校验入口。

## 2. 目标

- 将已验证的 Grafana 13.2.0、VictoriaLogs 插件 0.31.0 和 Explore 15 分钟默认范围沉淀为可复用配置。
- 让生产启动不依赖在线插件下载，并为离线或私有仓库交付提供明确流程。
- 对齐 Docker 与 Kubernetes 的低延迟、持久缓冲和时间戳保真策略。
- 将 VictoriaLogs 查询并发改为指标驱动调优，避免无证据放大资源争用。
- 增加本地与 GitHub Actions 校验，阻止漂移版本、明显凭据和危险默认值进入主分支。

## 3. 非目标

- 本次不把 VictoriaLogs 单节点改造成集群。
- 不新增 Prometheus、Alertmanager 或另一套监控平台。
- 不清理 Git 历史中的旧内容；当前文件中的真实口令样例会替换，并提示相关口令轮换。
- 不再次修改生产服务器；本次只更新仓库、验证并通过 PR 合并。

## 4. Grafana 设计

### 4.1 版本与插件

- 默认镜像固定为 `grafana/grafana:13.2.0-ubuntu`，不使用 `latest`。
- VictoriaLogs 数据源插件固定为 `0.31.0`。
- 提供自定义镜像构建文件，在构建阶段安装插件；生产容器启动时不设置 `GF_INSTALL_PLUGINS` 或其他在线安装变量。
- 删除已被 Grafana 禁用且仓库没有引用的 `grafana-piechart-panel` 和 `grafana-worldmap-panel`。

### 4.2 查询体验

- `GF_EXPLORE_DEFAULTTIMEOFFSET=15m`。
- VictoriaLogs 数据源使用稳定 UID `victorialogs-ds`。
- 默认最多返回 2000 行，数据源请求超时 60 秒，配置由 provisioning 管理且 `editable: false`。
- 文档明确：旧 Explore URL 中的 `range` 会覆盖全局默认值。

### 4.3 生命周期

- Grafana 优雅停止时间为 1 分钟。
- 健康检查提供 120 秒启动宽限，覆盖主版本升级时的 SQLite 和统一存储迁移。
- Compose 不保留废弃的顶层 `version` 字段。

## 5. VictoriaLogs 设计

- 保持已验证的 `v1.52.0` 单节点基线。
- 默认 `search.maxConcurrentRequests=4`，并参数化队列时长、查询时长、默认并行 reader 和慢查询阈值。
- 默认值对应已验证的 4 核主机和 3 CPU 容器上限；只有 `vl_concurrent_select_limit_reached_total` 或 timeout 持续增长时才提高并发。
- 保留 `SIGINT` 和 2 分钟优雅停止。
- distroless 容器不增加依赖 shell/curl 的伪健康检查；由宿主机校验脚本访问 `/health` 和 `/metrics`。
- 文档删除无条件将并发调到 16 的建议。

## 6. Vector 设计

### 6.1 Docker Compose

- 保持 Vector `0.58.0-alpine` 和 10 GiB 磁盘缓冲。
- 文件发现周期改为 5 秒，显式排除 `.gz` 和 `.tmp`，公平读取活跃文件并保留轮转读取窗口。
- Java 多行收束为 3 秒，发送批次超时为 1 秒。
- 保持 `when_full: block` 和真实时间戳，不以丢新日志或改写时间掩盖积压。
- 默认移除 console sink，避免业务日志再次写入容器 stdout；调试使用 `vector tap`。

### 6.2 Kubernetes

- 以现有 Containerd/Docker CRI 模板为已验证基线。
- 本次只修复与 Docker 基线、文档或校验相关的漂移，不无证据调整资源和轮转阈值。

## 7. 校验与交付

新增统一校验脚本和 GitHub Actions，至少覆盖：

- 三套 Compose 使用示例环境变量展开成功。
- Docker Vector 配置通过 `vector validate`。
- 两套 Kubernetes YAML 可解析，并抽取其中的 Vector 配置做验证。
- 禁止 `latest`、`GF_INSTALL_PLUGINS`、遗留 Angular 插件、`drop_newest`、`rewrite_timestamp` 和明显的真实口令样例。
- Grafana 默认范围、数据源 UID、最大行数和插件版本保持固定。

交付流程：创建功能分支，提交设计、实施计划和代码，运行完整验证，创建 PR；PR 检查通过后合并 `main`，最后确认远端主分支包含合并提交。

## 8. 回滚与兼容

- Grafana 13 会迁移 SQLite/统一存储；生产回滚必须恢复升级前数据库备份，不能只切回旧镜像。
- 插件包和镜像必须在切换前下载、校验并镜像到私有仓库。
- Vector/VictoriaLogs 升级只重建目标服务，保留磁盘缓冲、数据目录和精确旧镜像。
- 所有默认值均允许通过 `.env` 调整，但文档必须同时给出指标证据和回滚条件。
