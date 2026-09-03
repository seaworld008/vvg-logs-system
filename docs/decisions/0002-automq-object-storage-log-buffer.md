# ADR-002: AutoMQ + 对象存储作为中大规模日志缓冲层

- 状态：Accepted
- 日期：2026-09-04

## 背景

Vector 直写 VictoriaLogs 或 ClickHouse 的组件最少、延迟最低，适合小到中等规模且
下游稳定的环境。但在日志高峰、存储维护或下游抖动时，每个采集节点只能依靠本地
buffer，无法提供统一的 72 小时缓冲、集中 lag 可观测性和独立追赶能力。Redis list
也缺少 Kafka consumer group、partition、offset 和可控重放语义，不再作为新增日志
缓冲层。

## 决策

仓库长期维护两条受支持路线：

1. 小到中等规模继续使用 Vector 直写，作为低复杂度默认方案和 AutoMQ 第一回滚入口。
2. 中大规模、突发明显或需要隔离存储抖动时，使用
   `Vector -> AutoMQ + S3 -> Vector consumer -> VictoriaLogs/ClickHouse`。

当前部署采用用户批准的单节点 combined KRaft 例外，Broker 与已有监控、ClickHouse
共享宿主机。AutoMQ 固定 `3 CPU / 6 GiB` cgroup，但 JVM 与缓存使用官方 Tiny 参数：
Heap 1 GiB、Direct Memory 1.5 GiB、WAL cache 500 MiB、Block cache 100 MiB、upload
threshold 60 MiB。显式缓存不能按 6 GiB等比例放大，必须给 native memory、线程栈、
ZGC、网络和冷读峰值留出余量。

- Broker 镜像固定精确稳定版和 digest，不使用 `latest`；上线时重新筛选稳定 Release。
- 业务 Topic 预创建、72 小时 retention、4 MiB消息上限、关闭自动建 Topic。
- producer 使用 Zstd、`acks=all`、idempotence、无限消息重试和有界持久 disk buffer。
- producer 与 consumer 使用 librdkafka `rebootstrap`、完整 metadata刷新和有条件 watchdog。
- Gateway 必须在 Kafka 前完成解析、GeoIP 和脱敏，原始 header/body 不进入对象存储；
  16 MiB file source 上限保护 9000 行以上的大 JSON，解析后超过 4 MiB走直写兜底。
- VVG 保留原始事件时间；超过 4 MiB走带告警的 VictoriaLogs直写兜底。
- `kubernetes_logs` source 官方语义仍是 best effort 且不支持 source acknowledgement；
  不宣称从容器日志文件开始的严格端到端 at-least-once。
- 只在 VPC 内网发布 Kafka listener，使用 SCRAM-SHA-512 和最小 Topic/group ACL；对象
  存储保持私有、默认加密、最小 IAM 权限和受限 secret mount。
- 大屏与告警属于金龄云 SaaS 日志系统，放入对应业务组，不归入通用基础设施项目。

## 后果

该方案把后端维护窗口与采集节点解耦，并提供集中 offset、lag、重放和 72 小时缓冲；
代价是增加 Broker、对象存储、consumer、凭据、ACL 和监控运维。单 Broker 或本机
KRaft metadata 故障仍会中断服务，对象存储不能替代控制器高可用。producer 本地
disk buffer、自动恢复和备份只能缩小影响，不能把单节点变成高可用集群。

任一条件成立时，应迁移到至少 3 个独立 Controller/Broker 节点并重新压测，而不是
继续放大单机：

- 业务要求主机故障期间仍可持续生产和消费；
- 日志量或追赶流量使共享宿主机 CPU 持续超过 80%或可用内存低于 3 GiB；
- ClickHouse、监控或 AutoMQ 之间出现可测量的资源争用；
- 单节点维护窗口、恢复时间或 metadata 风险超过业务可接受范围。

## 被否决的替代方案

- 全部环境强制使用 AutoMQ：对小规模环境增加不必要的组件和故障面。
- 继续使用 Redis 作为新增日志队列：缺少本方案需要的 partition、consumer group、
  offset、重放和对象存储分层能力。
- 与 VictoriaLogs 存储放在同一节点：会让缓冲层和目标存储共享同一主机故障域，失去
  隔离下游故障的主要价值。
- 仅依靠客户端默认重连：实测长时间 leader 丢失后不足以保证自动追赶，因此保留
  rebootstrap、完整 metadata刷新、producer liveness 和 consumer watchdog。
