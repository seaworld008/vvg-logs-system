# ADR-001: 网关访问日志使用 Vector -> ClickHouse -> Grafana

## Status

Accepted

## Date

2026-09-02

## Context

VVG 主链路面向应用原始日志，使用 Vector、VictoriaLogs 和 Grafana。网关访问日志是结构化分析场景，需要频繁计算 QPS、PV/UV、状态码、延迟分位数、后端路由和多维 TOP N，并保留受控时间范围内的请求明细。

生产案例证明 ClickHouse 能有效承载这类聚合，但历史实现暴露了以下问题：Vector 忽略 checkpoint 导致重启重读风险；有限重试在 ClickHouse 异步写入等待期间丢批次；解析失败原文写入无界临时文件；ClickHouse system log 无 TTL 增长到远大于业务库；超宽排序键增加主索引和合并成本；Grafana 使用管理账号而非只读账号。

## Decision

新增独立的 `clickhouse-gateway/` 专区，不把 ClickHouse 强行并入现有 VictoriaLogs 组件：

- Vector `file` source 只读目标 Gateway CRI 文件，持久化 checkpoint 和 disk buffer；
- 使用经过样本验证的完整 JSON 提取，失败事件只保留脱敏技术诊断；
- ClickHouse sink 使用 gzip、acknowledgement、无限次退避重试和 180 秒请求超时；
- `DateTime64(3)` 使用 RFC3339 字符串传输，不依赖不同 ClickHouse 版本的数字时间戳推断；
- ClickHouse 使用月分区、时间优先的紧凑排序键和 30 天业务 TTL；
- ClickHouse system log 使用 7 天 TTL，运行容器有健康检查和资源边界；
- Grafana 使用固定 datasource/Dashboard UID 和只读用户；
- GeoIP 使用可再分发的固定版本 DB-IP City Lite，通过 GitHub Release、SHA-256 和原子替换交付，Dashboard 保留数据归属链接；
- 生产镜像先进入私有仓库，所有版本精确固定，正式启动不联网拉取或安装插件。

## Alternatives Considered

### 继续把网关数据写入 VictoriaLogs

适合全文检索，但现有 Dashboard 大量使用 SQL 聚合、精确分位数和多维分析。迁移查询会改变用户工作流，本次不采用。

### 引入 Kafka

Kafka 可以扩大后端长时间不可用时的保留窗口，但当前单集群吞吐由每节点持久 Vector buffer 足以覆盖计划维护。Kafka 会增加集群、磁盘、监控和消费语义复杂度；达到容量触发条件后再引入。

### 继续使用历史超宽 ORDER BY

历史查询能够工作，但几乎所有列进入排序键会扩大主索引并增加写放大。新项目使用时间和常用过滤维度组成的紧凑排序键；已有表只在专门迁移项目中重建，不能在线直接修改。

## Consequences

- 仓库同时维护 VictoriaLogs 原始日志和 ClickHouse 网关分析两条明确分离的路径。
- Gateway 输出 JSON 字段是公开契约，应用变更必须先经过 Vector 样本测试。
- 单节点 ClickHouse 仍存在维护窗口和主机故障风险；高可用需求应升级为副本/集群设计，而不是只扩大本机资源。
- Grafana 插件与 Dashboard 必须按固定版本验证；升级插件后重新执行查询和布局验收。
- GeoIP 月度更新会改变地域归属结果；升级必须作为独立、可审计的数据发布执行，不能使用现场云存储或浮动 URL。
- 生产账号拆分需要同步 Vector Secret 和 Grafana datasource，必须作为受控变更执行。
