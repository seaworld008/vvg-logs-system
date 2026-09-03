# AutoMQ + OBS 日志缓冲层部署、主切与回滚手册

> 当前验证目标：AutoMQ `1.7.4`、Vector `0.58.0`、华为云 OBS S3 API
>
> 部署形态：共享宿主机上的单节点 KRaft；不具备生产高可用能力

本文只覆盖 VVG 和 Gateway 两条现有日志链路。旧 ELK 的 `elk_redis`、Logstash、
Kibana、Elasticsearch，以及夜莺的 `redis-v9` 均不在本次变更范围。

本方案只作为中大规模日志的持久缓冲选项。仓库中的 VVG/Gateway 直写配置继续作为
小到中等规模环境的首选和本方案回滚基线，不得删除、改名或用生产者清单覆盖。

## 1. 不可省略的风险说明

- AutoMQ 官方生产建议至少 3 个 Controller/Broker 节点并独占资源；本方案是用户确认
  接受的单节点例外。
- Broker、宿主机或本地 KRaft metadata 不可用时，生产者只能依赖节点本地 Vector
  buffer 和容器日志保留窗口；OBS 不能替代可用的 Controller。
- data、ops 和 WAL 使用同一个 OBS 物理桶，分别用 bucket ID `0`、`1`、`0`。
  不使用普通 OBS 文件夹模拟 bucket prefix。
- 当前共享宿主机只有 4 CPU/16 GiB。AutoMQ 限制为 3 CPU/6 GiB，使用官方 Tiny
  内存参数：Heap 1 GiB、Direct Memory 1.5 GiB、WAL cache 500 MiB、Block cache
  100 MiB、upload threshold 60 MiB；不得临时取消
  cgroup 边界；可用内存低于 3 GiB或既有 ClickHouse/Grafana 延迟恶化时禁止主切。
- Kafka 批次使用 Zstd，以降低 VPC、WAL 和 OBS 容量；通过 500-event producer 批次、
  4 MiB consumer 预取和 2 GiB VVG consumer 上限控制解码放大，不通过关闭压缩规避。

## 2. 只读盘点

记录时间、主机、Docker/Compose、CPU、内存、无 Swap、磁盘/inode、监听端口、
全部容器的镜像、Compose ownership、StartedAt、资源限制、RestartCount 和 OOMKilled。
同时记录：

- VVG 每秒行数、消息字节、最大单条和 VictoriaLogs drop/error；
- Gateway 每秒行数、`max(createdtime)` 延迟、async insert failure；
- 两个 Vector DaemonSet 的镜像、data_dir、checkpoint、buffer 和 Pod 分布；
- 现有 Grafana、ClickHouse、VictoriaLogs、夜莺、Redis 的状态，证明未被重建。

## 3. OBS 与镜像门禁

OBS 必须是同区域、private、标准存储、SSE-OBS，WORM 和多版本关闭。IAM 用户只获得
目标桶的 List/Get/Put/Delete、multipart list/abort 权限。

应用 `config/obs-lifecycle.json`，仅在分片上传启动 7 天后清理仍未完成的分片。不得给
AutoMQ 数据对象设置基于对象年龄的过期删除规则；Topic 的 72 小时 retention 由 Broker
负责，OBS 生命周期越过 Broker 直接删除活跃对象会破坏日志和元数据一致性。

AutoMQ bucket URI 不设置 `checksumAlgorithm`。部署前依次验证：

1. S3 SigV4 Head/List；
2. 小对象 Put/Get/Delete，下载 SHA-256 与源一致；
3. multipart initiate/upload/complete/get/delete；
4. `automq-cli` 或 Broker readiness 对 data、ops、WAL 三个 URI 的真实检查；
5. 重启 Broker 后重新消费已确认消息。

镜像先从官方精确 digest复制到自建 Harbor，再由已登录的 CCE 管理节点从 Harbor拉取、
核对 digest并推送 SWR。目标宿主机从 Harbor/SWR获得同一内容，正式 Compose设置
`pull_policy: never`。不能仅比较 tag。

## 4. 备份与影子部署

在 `/data/automq/backups/<timestamp>/` 保存 Compose、渲染配置、镜像清单和主机基线。
在 CCE 管理节点的 `efk/vector-log/` 与 `efk/vector-gateway/` 各自保存真实源、
`vector-automq-shadow.yaml`、`vector-automq-production.yaml`、ConfigMap、DaemonSet 和
checkpoint 摘要。原配置进入各自 `backups/automq-pre-shadow-<timestamp>/`，并生成
SHA-256。秘密备份保持 `0600`，目录 `0700`；临时候选目录不能成为正式运维入口。

创建 ClickHouse 影子表时先保存正式表 `SHOW CREATE`，然后使用同结构创建
`nginx_access_automq_shadow` 并把 TTL 调整为 3 天。VVG 影子数据写入 tenant `99:99`。

shadow 清单必须满足：

- VVG state `/var/lib/vector-automq-vvg-shadow`、metrics hostPort `9598`；
- Gateway state `/var/lib/vector-automq-gateway-shadow`、metrics hostPort `9599`；
- `maxUnavailable: 1`、独立 Secret、独立 ConfigMap、独立 selector；
- VVG Kafka buffer 10 GiB，Gateway 2 GiB，均 `disk + block`；
- 下游 consumer 依靠 Kafka offset 重放，使用有界 `memory + block`，不再叠加 Vector
  disk v2 buffer；生产者 Pod 和消费者容器的优雅停止时间均为 120 秒；
- 解析、字段、GeoIP、脱敏逻辑来自当前真实 manifest，不来自过期公开副本。
- Gateway shadow 的 checkpoint 与 GeoIP 数据必须分卷；已校验的正式 GeoIP 目录只读
  复用，不能让 shadow init 容器重新联网下载。

## 5. 当天门禁

以下任何步骤失败都停止在当前安全状态，不压缩等待时间：

1. 发送/消费普通消息、接近 4 MiB边界消息，并确认未授权用户被拒绝。
2. 按当前总吞吐 3 倍持续压测 30 分钟，Broker/OBS 无错误，宿主机无资源门禁触发。
3. 两条 shadow 链路运行至少 90 分钟；用已经沉降的固定窗口比较数量、字节、
   level/status 分布、时间戳和抽样内容哈希。
4. 停止两个 shadow consumer 10 分钟，确认原直写正常、Kafka lag增长；恢复后 lag归零，
   无 drop或 retry exhausted。
5. 优雅重启单 Broker，确认 producer disk buffer 增长后回落、无日志丢弃、OBS 无损坏。
6. 先停止 Gateway shadow producer，再启动 production consumer group，确认 group offset
   从当前末尾建立；随后滚动主 Vector producer并观察至少 45 分钟。
7. VVG 重复相同顺序并观察至少 90 分钟。超过 4 MiB的 VVG 事件继续通过带告警的
   VictoriaLogs直写兜底。

主切验收必须同时满足：宿主机可用内存不少于 3 GiB，CPU 连续 10 分钟低于 80%，
所有新增容器 RestartCount=0/OOMKilled=false，ClickHouse/VictoriaLogs 写入延迟无恶化，
Kafka/Vector错误和 OBS 4xx/5xx为零。

## 6. 监控

AutoMQ Prometheus监听容器内 `8890`，宿主机仅绑定 loopback。两个 consumer 分别暴露
`9598`/`9599`，CCE producer 使用同样的 hostPort。固定版 vmagent 抓取这些端点和
本机 node-exporter，remote write到现有 VictoriaMetrics。

导入 `monitoring/grafana/automq-cluster.json` 到现有监控 Grafana，datasource变量绑定
现有 VictoriaMetrics；将原生夜莺大屏和 `monitoring/alert-rules.yml` 一起导入金龄云
SaaS 业务组，不得放入通用基础设施或其他项目业务组。至少验证 Broker down、
Controller、S3 request error、Kafka request error、consumer lag、producer queue、
可用内存和 CPU告警均可产生并恢复。

## 7. 回滚

1. 停止对应 production producer 的继续滚动，记录当前 Topic end offset和 consumer lag。
2. 应用升级前真实 manifest，让原 Vector恢复 VictoriaLogs/ClickHouse直写并等待 Ready。
3. 保持 production consumer 运行，排空已经确认进入 AutoMQ 的消息；不得先删除 Topic。
4. 核对后端时间连续性、计数、错误、Pod restart和 buffer后再停止消费者。
5. AutoMQ 回滚恢复对应 Compose、runtime 和完整 KRaft metadata；不要只切镜像。
6. 未证明无需恢复前，不删除 OBS 对象、Topic、影子表或备份。

回滚完成后重新验证现有 Dashboard UID、datasource、查询字段和最近 15 分钟业务日志。

## 8. 已验证的生产经验

- 稳定版筛选必须同时排除 draft、prerelease 和名称中的 `rc/alpha/beta/nightly`；不能
  只信 GitHub `latest` 或 prerelease 标记。
- 单节点 combined KRaft 开启 StandardAuthorizer 时，Controller 也必须使用认证身份；
  不得把 `User:ANONYMOUS` 加入 super users。External/Internal SCRAM listener 都要有
  显式 JAAS，AutoBalancer 固定走 Internal listener。
- CCE 使用独立 Pod 网段时，不配置源 IP 白名单；Kafka 只绑定 VPC 内网地址，并依靠
  SCRAM、Topic/group ACL 和云侧“不发布公网”边界。
- SSE-OBS 对象的 ETag 不等于明文 MD5。OBS 预检必须下载后比较 SHA-256，不能把
  `obsutil -vmd5` 的 ETag 比较当作数据损坏。
- Producer 的 `message_timeout_ms` 必须为 `0`，让有界 disk buffer 在 Broker 长时间
  恢复期间持续重试；默认 5 分钟会在门禁跨过该窗口后产生不可接受的丢弃。
- Producer 按 AutoMQ 吞吐建议使用 `linger.ms=100`、Vector `batch.max_bytes=1 MiB`、
  `metadata.max.age.ms=60s` 和 Vector 自带 librdkafka 的默认 Zstd level。保留
  `acks=all + idempotence`，不启用
  实验性的 gapless guarantee。
- VVG 的 Vector `kubernetes_logs` source 在官方能力表中是 `delivery: best effort`、
  `acknowledgements: no`。因此不能把整条链路表述为“从容器日志文件开始严格
  at-least-once”：节点或 Vector 在 source checkpoint 已推进、事件尚未可靠进入 disk
  buffer 的极小故障窗口仍可能丢失。Kafka sink 的 `acks=all + idempotence`、持久
  disk buffer，以及 AutoMQ consumer 到 VictoriaLogs 的 acknowledgement/replay 仍然
  保护 source 边界之后的链路。必须监控 source checkpoint、producer buffer 和
  discarded/error counter，并在容量或合规要求不接受该窗口时改用支持端到端 ack 的
 采集协议/source。参考 [Vector Kubernetes logs source](https://vector.dev/docs/reference/configuration/sources/kubernetes_logs/)。
- VVG producer 使用两个按 partition key 确定性分流的 5 GiB Kafka lane，提高积压
  追赶并保持总上限 10 GiB。每 lane 使用 Zstd、最多 500 events 的批次。
- Kafka consumer 不能叠加 Vector disk v2 buffer。Kafka offset 已提供持久重放，
  consumer 使用 `memory + block`；压缩批次的预取按压缩后字节计，必须限制 fetch、
  receive 和 queued bytes。VVG 的 12 个分区由 3 个 `1.5 GiB` consumer共同处理，避免
  单进程承接全部分区时 JSON 解码放大触发 cgroup OOM。
- Producer 与 consumer 都显式使用 librdkafka `rebootstrap`，30 秒重新使用 bootstrap
  地址并刷新 metadata；单节点 leader 长时间为 `-1` 后还要关闭 sparse metadata，强制
  获取完整 Topic/leader 元数据。consumer 的低预取队列配合 `fetch.queue.backoff.ms=100`。
- Vector 0.58 的 producer 在实测中仍可能停留在旧的 `Leader: -1` 会话。producer Pod
  使用保守 liveness 兜底：Broker 不可达时不重启；仅当 Broker 已可达、Kafka disk
  buffer 超过正常抖动阈值且队列连续 90 秒没有下降时才重启。只检查发送计数是否偶尔
  增长会漏掉“连接存在但追赶吞吐接近零”的半卡死状态。buffer 位于 hostPath，
  新 Pod 必须从同一 ledger 继续排空。
- Consumer watchdog 先检查 Gateway，再检查 VVG；同一 group 的多个 consumer 并行
  执行 120 秒优雅重启。禁止让影子 VVG 的串行停止窗口阻塞正式 Gateway 的恢复。
- Broker 健康不能只验证 Kafka API 端口；combined KRaft 重启时端口可能先于业务
  partition leader 就绪。健康检查必须同时确认两个业务 Topic 均无 `Leader: -1`。
- 6 GiB 容器内把 Heap、Direct、WAL 和 Block 按比例放大，在真实 Gateway 主切和 VVG
  积压追赶中两次触发 cgroup OOM。最终保留 3 CPU/6 GiB cgroup，但恢复官方 Tiny 内存
  参数，为 native、线程栈、ZGC、网络和冷读瞬时内存保留约 3 GiB；不得只按各显式
  缓存之和小于容器上限来估算内存。
- Gateway 先完整读取并解析超长多行 JSON，再把脱敏结构化事件送 Kafka。不得在解析前
  截断；`file.max_line_bytes` 显式设为 16 MiB，避免 Vector 默认 100 KiB 单行上限在
  multiline/VRL 之前丢弃大 JSON。`max_read_bytes` 只控制文件间读取公平性，不能替代
  单行上限。解析后超过 4 MiB时直写 ClickHouse fallback，且凭据来自 Kubernetes Secret。
- 生成清单的多行 VRL/命令必须使用 YAML `|` block scalar，并把配置 SHA-256 放入
  Pod annotation，保证可读且 ConfigMap 变化会触发受控滚动。
