# 共享宿主机负载与日志链路性能排查

适用于 AutoMQ、ClickHouse 和监控服务共享宿主机，VVG consumer 与 VictoriaLogs
同机放置的部署。先按 `AGENTS.md` 读取相关运行手册。本文保存通用方法和脱敏结论，
服务器地址、账号、原始监控序列和业务日志只保留在受控环境。

## 先解释告警，再定位进程

“5 分钟单核平均负载”不是 CPU 使用率。Linux load 包含等待 CPU 和不可中断等待的
任务；单核口径需结合实际逻辑 CPU 数与云监控定义核对。不能因为 load 超阈值就降低
日志吞吐、取消压缩或提高告警阈值。

对齐同一告警窗口，至少同时查看：

- `node_load5`、CPU idle/iowait/steal、可用内存、Swap、磁盘忙碌和延迟。
- `docker stats` 的容器总开销与 Broker `jvm_cpu_time_seconds_total` 的进程开销。
- Docker healthcheck 的实际开始/结束时间，以及 watchdog 的 timer 和执行耗时。
- Produce P99、S3/Kafka 错误、consumer lag、producer 每条 lane 的 buffer 和发送速率。
- VictoriaLogs 写入/drop/select-limit 增量、ClickHouse async insert 失败和最新写入时间。

容器 CPU 百分比按单核统计，不能直接等同于整机使用率。只看 Broker JVM 指标还会
漏掉同一容器内的临时 Java 管理进程。没有错误指标序列时记录“未暴露”，通过日志及
其他计数交叉确认，不能把空查询自动当作零。

Kafka request error 必须按 `type,error` 拆分。Kafka 3.9 的 AdminClient 会先尝试
`ConsumerGroupDescribe`，收到 `UNSUPPORTED_VERSION` 后退回 classic `DescribeGroups`。
因此 watchdog 成功返回 group 状态时，仍可能增加该协议协商计数；这不能直接等同于
Produce/Fetch 失败，也不能笼统报告“所有 Kafka error 为零”。保留原告警规则，结合
命令退出码、group 状态、lag 和实际数据请求错误判断，不批量屏蔽所有错误。

```bash
date -Is
uptime
nproc
free -m
vmstat 1 10
docker stats --no-stream
docker inspect automq --format '{{json .State.Health}}'
systemctl show automq-consumer-watchdog.service -p Result -p ExecMainStatus
```

上述 inspect 只取健康状态。不要把完整含环境变量的容器 inspect 上传到 Issue 或 PR。

## 避免探测本身制造负载

AutoMQ `1.7.4` 的 Kafka CLI 会继承 `KAFKA_HEAP_OPTS` 和
`KAFKA_JVM_PERFORMANCE_OPTS`。Broker 的 Heap 1 GiB 和 ZGC 适合长期运行的服务，
不适合每隔十几秒重新启动的管理命令。一次健康检查依次运行 API versions 和两个
Topic describe，会启动三个 JVM。

当前修复保持健康检查间隔、SCRAM 认证及 Topic readiness 的含义：

1. 用一次认证后的 `kafka-topics.sh --describe` 查询两个精确 Topic。
2. Topic 名先限制为合法字符，再转义点号并构造带首尾锚点的正则，避免匹配近似名称。
3. 要求两个 Topic 均有正整数 `PartitionCount`，分区号完整、不重复且所有 leader 非负。
4. 命令最多运行 15 秒；失败、超时、空结果、缺失 Topic 或部分分区均返回不健康。
5. 仅在健康检查及 watchdog 管理命令中使用 `-Xms32m -Xmx128m`、SerialGC 和
   `ActiveProcessorCount=1`。Broker 的 Heap、Direct Memory、ZGC、3 CPU/6 GiB 不变。

128 MiB 是当前小型固定双 Topic 集群的探测预算。扩大 Topic/partition 数量时需要
重新测量 CLI 内存和最慢耗时；不得把该预算推广为所有 Kafka 集群的通用配置。

使用相同目标、相同认证、相邻时间的串行样本对比，记录 wall time、user CPU 和
system CPU。不要高频运行 `docker stats`、Kafka CLI 或额外压测来干扰生产测量。

```bash
docker exec automq bash -c '
  TIMEFORMAT="elapsed=%R user=%U system=%S"
  time /opt/automq-deploy/healthcheck-kafka.sh
'
```

首次修复的对照验证显示，单次探测 CPU 时间降低约七成。这个比例只描述管理探测，
不代表日志吞吐提升七成；整机负载还取决于其他服务、流量和任务调度。

## 区分积压和 producer 卡死

输入高于发送速度时，队列会增长，但 producer 可能仍在正常满速发送。只用“队列
连续不下降”作为 liveness 条件，会在日志高峰误重启，并让正在追赶的采集器再次暂停。

当前检查逐条 Kafka lane 保存 queue、累计发送字节和采样时间，仅在以下条件同时
成立时返回失败，再由 Kubernetes 的三次连续失败触发恢复：

- Broker TCP 可达。
- 该 lane 的队列超过原高水位且没有下降。
- 该 lane 的实际发送速率低于对应链路的判断下限：VVG 为 `65536 bytes/s`，
  Gateway 为 `8192 bytes/s`，由生成器显式写入环境变量。

这些值是判断停滞的下限，不是生产限速。Gateway 单事件较小，正常发送量可能低于
64 KiB/s，不能照搬 VVG 阈值；应按每条链路正常流量的实际字节速率留出余量。可通过
`AUTOMQ_STALL_MIN_SENT_BYTES_PER_SEC` 覆盖，但必须用真实正常峰值和半卡死样本验证。
不得退回“发送计数有任何增长就健康”，否则偶发少量发送会掩盖半卡死；也不得汇总
所有 lane 的发送速率，否则健康 lane 会掩盖另一条卡死 lane。

队列下降、低水位、首次观察、发送计数重置及过长采样间隔都重新建立观察基线。
Broker 不可达时清除历史且不重启 producer。指标无法读取或解析时不伪造零队列。
Prometheus 文本解析兼容带 timestamp 和不带 timestamp 的样本。

producer 除了磁盘 buffer，还有 librdkafka 内存队列。两个 lane 各允许 256 MiB 时，
内存排队上限合计达到 512 MiB，尚未计入编码副本、压缩、source 和其他转换状态。
Broker 断连时曾触发 2 GB producer 的 OOM。当前每个 Kafka sink 将
`queue.buffering.max.kbytes` 限为 `65536`，双 lane 合计 128 MiB；继续保留总计 10 GiB
disk/block、无限重试、ack、Zstd 和原批次。该调整限制驻留排队，不是吞吐限速；
上线后仍需比较正常吞吐、恢复追赶速率和内存峰值，不能据此宣称绝不 OOM。

## Broker 重建的恢复门禁

重建已有 Broker 验证的是持久状态恢复，不等于空 Topic/空 KRaft 的首次部署验证。
计划重建时备份配置、消费 offset 和容器基线，优雅停止后保存一致性 KRaft metadata，
再用原精确镜像 `up -d --no-deps --force-recreate automq`。不执行空数据初始化，
不删除 Topic、offset、OBS 或 producer checkpoint。

Vector 0.58 客户端在 Broker 重建后曾停留在失效的 coordinator/leader 会话。必须分层
验证，不能把 Broker healthy、consumer group Stable、有成员或 consumer 自报 lag=0
当作全链路恢复。用认证后的 Kafka CLI 查询每个 production group 的 committed offset
与 log end offset，并核对后端最新事件时间：

```bash
docker exec \
  -e KAFKA_HEAP_OPTS='-Xms32m -Xmx128m' \
  -e KAFKA_JVM_PERFORMANCE_OPTS='-XX:+UseSerialGC -XX:ActiveProcessorCount=1' \
  automq timeout 20 /opt/automq/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:19092 \
  --command-config /etc/automq/admin-client.properties \
  --describe --group PRODUCTION_GROUP
```

Broker healthy 后若真实 lag 上升、committed offset 不动且后端时间不推进，按现场
所有权恢复对应消费者。远端三个 VVG 实例不属于 Broker 主机的本地 watchdog：在其
目标主机执行 `docker restart -t 120`；同组全部确认停滞时可并行优雅重启，避免逐个
等待导致恢复窗口叠加。只恢复必要实例，检查 group 重平衡、offset 继续推进、lag 回落
及下游最新时间。`AssignmentLost` 可能使已处理而未提交的消息重放，不能把重放
误判为新流量，也不能仅凭 drop counter 没增长承诺整个 source 边界绝无丢失。

producer liveness 仍保留低速停滞恢复。等待 120 秒优雅退出时，metrics/readiness
可能暂时不可用；不要在原恢复尚未结束时叠加删除 Pod、复制活动 disk buffer 或多次重启。
出现 OOM 时必须记录，而不能把自动重启后的 Running 状态描述成“全程零 OOM”。
当前版本的 consumer 自动恢复仍有此边界，本地 Empty-group watchdog 不覆盖远端
Stable-but-stalled group；计划维护必须包含上述主动恢复和验收步骤。

## 发布与验收

先核对仓库修复是否已经进入现场活动配置。拉取最新 Git 不会自动更新服务器：检查
`bootstrap-cluster.sh` 的有界认证 API 等待，确认 `automq-bootstrap` 依赖
`service_started`，consumer 同时依赖 bootstrap 完成和 Broker Topic healthy。
旧配置可能仍有“健康等待 Topic，bootstrap 又等待健康”的冷启动循环。同步修复时
备份现场 Compose，只修改这两处依赖并结构化比对，使用目标机实际 Compose 展开；
可以先发布脚本和启动配置，不执行 bootstrap，不修改已有 Topic/ACL，也不重建 Broker。
冷启动回归测试通过不等于已经对生产集群执行了清空重建演练。

Broker 的脚本目录是目录 bind mount。先备份脚本、Compose 和容器状态并验证 SHA，
在同一目录原子替换脚本，随后执行认证健康检查；无需重启 Broker。单文件 bind mount
不适用这个结论，必须检查实际挂载。

producer 的健康脚本通过 ConfigMap `subPath` 挂载。仅更新 ConfigMap 不会让运行中的
Pod 使用新脚本。必须从现场当前源清单生成候选，结构化比较确认只改健康脚本及配置
hash，再按 `maxUnavailable=1` 滚动。滚动前确认队列已回到低水位，保留原 data_dir、
checkpoint、disk/block、ack、压缩、解析、镜像和资源限制。

分别保存以下验证证据：

- Broker 脚本更新前后的镜像、StartedAt、重启、OOM、资源限制和健康结果。
- 新 producer 的脚本 SHA、Ready、重启、错误增量及持久目录。
- 同时长变更前后 CPU/load、输入流量、lag、队列、Produce P99、后端写入与查询。
- 至少 15 分钟连续观察；不能用瞬时 `docker stats` 或单次 lag 归零宣称告警永久消失。

容量告警保留，优先消除可证明的浪费及误重启。若仍持续饱和，再用业务吞吐和后端
延迟评估独立主机或扩容，不以放宽告警掩盖瓶颈。

故障时恢复对应脚本或现场源清单，重新核对健康和数据连续性。不得删除 Topic、offset、
OBS 对象或 checkpoint；软件版本和数据格式没有变化时不做无关的数据恢复。

## 回归验证

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
python3 scripts/render-automq-example-manifests.py --check
bash scripts/validate-configs.sh --static
bash scripts/validate-configs.sh --runtime
git diff --check
```

覆盖健康双 Topic、缺分区/重复分区、错误/超时、正则转义、独立 CLI JVM、watchdog
恢复边界，以及 producer 高吞吐积压、慢速半卡死、单 lane 卡死、counter reset 和指标缺失。

参考：[华为云 Agent 指标](https://support.huaweicloud.com/usermanual-ecs/ecs_03_1003.html)、
[Kafka TopicCommand](https://github.com/apache/kafka/blob/3.9.1/tools/src/main/java/org/apache/kafka/tools/TopicCommand.java)、
[Kafka consumer group 协议回退](https://github.com/apache/kafka/blob/3.9.1/clients/src/main/java/org/apache/kafka/clients/admin/internals/DescribeConsumerGroupsHandler.java)、
[Vector Prometheus exporter](https://vector.dev/docs/reference/configuration/sinks/prometheus_exporter/)。
producer 内存队列语义见 [librdkafka 配置](https://github.com/confluentinc/librdkafka/blob/v2.10.1/CONFIGURATION.md)。
