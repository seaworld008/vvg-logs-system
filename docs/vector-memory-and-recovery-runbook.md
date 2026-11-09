# Vector 内存、长日志与恢复基线

本手册覆盖 VVG / Gateway 两条生产链路的 collector、Kafka consumer 及旁路。
最后核对版本：Vector `0.58.0`（2026-09-07）。以下参数是本仓库的当前基线，
不是所有流量规模的容量承诺。真实地址、凭据、原始日志和监控序列不得进入 Git。

## 当前配置

| 角色 | 持久或内存排队 | 并发与批次 | 容器边界 |
|---|---|---|---|
| VVG producer | 两条 Kafka lane，每条 native queue 64 MiB；各 5 GiB disk/block | Zstd、500 events / 1 MiB、1 秒、linger 100ms；ack + idempotence | 保留现场 CPU/内存；公开模板 2 GiB，不能把现场十进制 `2G` 当成 `2Gi` |
| Gateway producer | Kafka native queue 64 MiB、2 GiB disk/block | 与 VVG 相同的 Kafka 批次和交付语义 | 公开模板 1.5 GiB（GeoIP 库常驻内存，1 GiB 时现场占用约 67%） |
| VVG consumer | 每实例 memory/block 64 events；保留 Kafka offset | 每批最多 512 KiB / 500 events，1 秒；最多 2 个在途 HTTP 请求 | 三实例各 1 CPU / 1.5 GiB，独立 state 与 metrics |
| Gateway consumer | memory/block 16 events；保留 Kafka offset | 每批最多 2 MiB / 2000 events，1 秒；最多 2 个在途请求 | 0.5 CPU / 512 MiB |
| Gateway 大事件 fallback | 解析和脱敏后使用 1 GiB disk/block | 单个在途请求，保留 180 秒超时和异步写入确认 | 与 Gateway producer 共用资源边界 |

consumer 不使用 Vector disk v2 buffer；持久重放由 Kafka offset 承担。
Gateway fallback 属于采集端的独立 ClickHouse sink，因此应使用持久磁盘缓冲。
切换前确认旧 memory fallback 已排空、data_dir 持久且磁盘余量满足新增 1 GiB。

## 为什么收紧排队

事件数上限不是内存字节上限。Gateway consumer 原 5000-event 队列面对接近 4 MiB
的事件时，理论 payload 总量远大于 512 MiB 容器。当前改为 16 events，VVG consumer
改为 64 events，并限制在途请求数量。批次的 `max_bytes` 也不是单事件硬限制，首个
大事件可能独自组成一批；评估内存还要计入 Kafka 预取、解码、对象开销和编码副本。

这些配置将背压尽早传回 Kafka 或 producer 的磁盘缓冲，不通过丢弃、取消压缩、
限制重试次数、减少采集范围或缩短日志保留期降低内存。正常流量下 buffer 应保持
低水位；如果吞吐下降或真实 lag 持续上升，应比较下游请求耗时与 CPU，再调整并发。
不得仅为使监控数字好看而任意压低 CPU 或增加内存上限。

consumer 的 session timeout、fetch 预取、重连配置，本轮保持已经部署的基线。
当前没有证据支持把这些参数同时改小；一轮只改变可验证的内存排队与在途数量。

## 正常长日志完整保留

日志行数和字节数是不同维度。9000 多行的 Java 日志，只要字节数在实际采集与后端
接收边界内，仍按原日志头和空闲超时完整合并，不设置固定 512 行拆段，也不新增
强制定时拆段。CI 使用实际 Vector 验证 9000 行正文合并成一条记录，并逐字节比对。
Gateway 继续运行已有的 9000 行 JSON 及超 100 KiB 单行解析测试；其 file source 的
`max_line_bytes: 16777216`、解析与 GeoIP 不因内存排队优化而缩小或替换。

本轮明确不加入无损关联分片、分片还原工具或另一套原文存储。现有边界必须如实说明：

- VictoriaLogs 单条记录约 2 MiB 是后端硬限制，不能通过提高请求大小无限放大。
- 当前 VVG 仍保留历史极端路径：序列化事件超过 16,000,000 字节时只保留正文前段并
  附加原始大小/摘要。它不是无损保存，摘要也不能恢复被移除的内容。
- Kafka 的 4 MiB Topic 限制、单物理行读取限制、合并后的记录大小和 HTTP request
  大小需要分开检查；不能把 4 MiB Kafka 门禁理解成 VictoriaLogs 的单条接收能力。
- 目前 `kubernetes_logs` source 的能力边界仍是 best effort，source checkpoint 与
  sink 持久确认之间存在故障窗口。不能仅凭 drop counter 没增长宣称任何情况下都零丢失。

上述极端边界作为独立风险保留，不为罕见超限事件继续引入新的复杂方案。出现实际
超限事件时先记录字节规模与来源，再做独立方案评估。

## 2026-11 现场复盘：多行边界、追赶内存与配置漂移

测试与生产 Kubernetes 采集端、主机 Compose 采集端的一轮排查，结论如下。数值来自
现场实测，用于理解量级，不是容量承诺。

### 访问日志必须被识别为“新条目”

`enhance_multiline` 的 `starts_when` 原来只认时间戳和 `INFO/WARN/...` 开头。前端容器
（H5、大屏、管理端静态站）输出的 Nginx/combined 访问日志以 `IP - - [时间]` 开头，
永远不匹配，于是每一行都被当成“上一条的续行”。只要流量连续、没有 3 秒空闲，几十万行
会被合并进同一条记录：现场单个容器最大约 30 万行。

- 影响：reduce 状态无界增长，collector 内存偏高；单条记录容易逼近 Kafka 4 MiB 或
  VictoriaLogs 2 MiB 边界；访问日志无法按行检索。
- 处理：`starts_when` 增加 `\d{1,3}(?:\.\d{1,3}){3}\s`（IPv4 + 空格开头 = 新条目）。
  生产两个 collector 内存由约 578/916 MiB 降到约 280/436 MiB，之后稳定在约 400 MiB。
- 回归：`scripts/test-vvg-multiline-preservation.sh` 同时验证 9000 行 Java 正文逐字节
  合并为一条、3 行访问日志保持 3 条。
- 以后接入新的非 Java 格式（logfmt `ts=`/`level=`、自定义前缀等）时，同样先补日志头
  规则和合成测试；不能用行数上限掩盖边界错误。

### 不用 `max_events` 截断正常长日志

排查中曾临时给 reduce 加 `max_events`，复查后撤回。网关 `system-gateway-server` 合法的
多行日志（格式化 JSON 响应体）实测最大 17,448 行、约 381 KiB，远低于字节边界；任何
固定行数都会把它拆成多条。真正的失控来源是上一节的访问日志边界，修正后无需行数上限。
仓库继续保持“正常多行日志按日志头和空闲超时完整合并”的基线，CI 断言 reduce 中没有
`max_events` 和 `end_every_period_ms`。

### 主机 Compose 采集端：重启后追赶的内存与资源漂移

一台主机的直写采集端有 40 个 file source。节点重启后需要追赶停机期间的日志，内存上涨，
而 Compose 上限仍是 1 GiB，于是约 2 小时内每分钟被 OOM 杀一次（共 124 次），直到有人
用 `docker update` 把运行中容器改成 2 GiB。问题在于 Compose 文件没有同步，下次重建会
退回 1 GiB 并再次进入 OOM 循环。

| file source 数量 | 实测稳态内存 | 建议上限 |
|---|---|---|
| 2～6 个 | 约 400 MiB | 1 GiB |
| 40 个 | 约 1.4 GiB（峰值触及 2 GiB） | 2 GiB |

- `docker-compose/vector/host-automq/compose.yaml` 的内存上限改为 `VECTOR_MEM_LIMIT`
  （默认 `1g`，同时作为 memswap）。超过约 20 个 source 时建议 `2g`，并在节点计划重启后
  观察追赶期间的峰值。
- 热更新资源可以用 `docker update`，但必须在同一次变更里同步 `.env`/Compose 并执行
  `docker compose config` 校验；README 和 SHA256SUMS 同步更新。
- 统计内存时区分匿名内存和文件缓存：cgroup `memory.stat` 的 `anon` 才是真实堆，
  `docker stats` 会扣除 inactive file 但仍包含 active file。

### 应用清单前先对比线上

测试集群一次调优直接 `kubectl apply` 了服务器目录中的清单，而该文件早已落后于线上：
VictoriaLogs 地址是旧值，还缺少 `cluster/environment/project/service` 四个标签。结果约
15 分钟的日志发往无人监听的地址。disk buffer + `when_full: block` 保住了数据，修复后全部
补送，按事件时间统计没有缺口；但这段时间约 7.8 万行没有那四个标签，已无法回填。

- 改任何现场清单前：导出线上 ConfigMap/DaemonSet，`kubectl diff -f <文件>` 确认文件与
  线上一致；不一致时先按线上重建文件并说明，再叠加本次改动。
- 应用前再次 `kubectl diff`，结果只能包含批准的字段；应用后 diff 应为空。
- 只改 ConfigMap 时 DaemonSet 不会滚动。生产清单用 `vector-config-sha256` 注解触发滚动，
  值应等于新 `vector.yaml` 内容的 SHA-256（生成器会自动计算）；现场曾发现该注解与配置
  不符，修改时一并纠正。不要用 `kubectl rollout restart` 制造文件与线上的漂移。

### 探针超时

直写模板的 readiness/liveness 原来使用默认 1 秒超时。负载高时 `/health` 偶尔超过 1 秒，
readiness 失败，liveness 失败还会重启并重放。直写模板改为 `timeoutSeconds: 5`、
`failureThreshold: 5`；AutoMQ producer 的 liveness 仍由生成器固定为 10 秒 / 3 次。

## 恢复判据

VVG 与 Gateway 使用不同的低速判断下限：VVG 64 KiB/s、Gateway 8 KiB/s。Gateway
正常字节吞吐较低，不能直接照搬 VVG 的下限。liveness 还必须同时满足 Broker 可达、
对应 lane 超过队列高水位且不下降、连续三次低速；健康 lane 不得掩盖卡死 lane。
Broker 不可达时不循环重启 collector，保留持久 disk buffer。

原镜像 Broker 重建实测证明：

- Broker 可以从持久 KRaft 状态恢复，但部分 Vector 客户端仍可能停留在旧会话。
- `Running`、group `Stable`、有成员和 consumer 自报 lag=0，不足以证明恢复。
- 必须用认证 Kafka CLI 检查真实 committed/end offset，结合后端最新日志时间确认。
- producer 的 liveness 恢复和 consumer 的主动恢复可能需要等待 120 秒优雅退出。
- 远端 VVG consumer 不归 Broker 主机的本地 Empty-group watchdog 管理。

当前版本不能承诺所有客户端在 Broker 重建后自动恢复。计划维护必须准备目标机
consumer 恢复步骤，并验证真实 lag 持续下降、日志时间回到当前、没有反复 OOM。
完整操作与资源归因见 [共享宿主机负载运行手册](shared-host-load-runbook.md)。

## 配置源与发布

1. 读取当前真实 ConfigMap、DaemonSet、consumer YAML、Compose ownership、镜像 digest
   和容器资源。核对 binary `vector --version`，不能仅凭 tag 或不同层级的 digest 判断升级。
2. producer 候选从现场当前源清单生成，保留所有解析、过滤、GeoIP、checkpoint 和 Secret。
   公开例子不能覆盖现场 YAML。结构化比较应只出现批准的 queue、buffer、并发或健康字段。
3. 使用同一精确 Vector 编译候选，再执行生成清单与完整 CI 校验。
4. ConfigMap subPath 更新需滚动 Pod。按 `maxUnavailable=1` 发布，禁止并行删除所有 collector。
5. consumer YAML 是单文件 bind mount，原子替换后必须重建对应 consumer；普通 restart
   可能继续使用旧 inode。逐实例恢复并核对镜像、CPU、memory、swap、state 和消费进度。
6. 保留至少 15 分钟观察，比较输入/发送量、真实 lag、后端时效、内存峰值、重启和错误。
   shutdown/OOM 历史记录与新配置启动后的增量必须分别说明。

查询最新稳定版时同时排除 draft、prerelease 和非 Vector 的工具 release。官方 release
列表可能把 `vdev-*` 开发工具标为 latest；只匹配 `vMAJOR.MINOR.PATCH` 的正式 Vector
版本，再做兼容性验证。本轮核实最新正式版本仍为 `v0.58.0`，未进行无依据的镜像升级。

## 仓库校验

```bash
python3 scripts/render-automq-example-manifests.py
python3 scripts/render-automq-example-manifests.py --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
bash scripts/validate-configs.sh --static
bash scripts/validate-configs.sh --runtime
git diff --check
```

实现、模板、验收测试和文档必须在同一个 PR。未完成真实故障注入的配置优化，只说明
已经验证的范围，不能把“候选可编译”或“恢复后 Running”写成长期零 OOM 的保证。

参考：[Vector 正式版本](https://github.com/vectordotdev/vector/releases/tag/v0.58.0)、
[Vector Reduce](https://vector.dev/docs/reference/configuration/transforms/reduce/)、
[librdkafka 排队参数](https://github.com/confluentinc/librdkafka/blob/v2.10.1/CONFIGURATION.md)、
[VictoriaLogs 单条大小限制](https://docs.victoriametrics.com/victorialogs/faq/#what-length-a-log-record-is-expected-to-have)。
