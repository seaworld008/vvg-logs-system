# Vector 内存、长日志与恢复基线

本手册覆盖 VVG / Gateway 两条生产链路的 collector、Kafka consumer 及旁路。
最后核对版本：Vector `0.58.0`（2026-09-07）。以下参数是本仓库的当前基线，
不是所有流量规模的容量承诺。真实地址、凭据、原始日志和监控序列不得进入 Git。

## 当前配置

| 角色 | 持久或内存排队 | 并发与批次 | 容器边界 |
|---|---|---|---|
| VVG producer | 两条 Kafka lane，每条 native queue 64 MiB；各 5 GiB disk/block | Zstd、500 events / 1 MiB、1 秒、linger 100ms；ack + idempotence | 保留现场 CPU/内存；公开模板 2 GiB，不能把现场十进制 `2G` 当成 `2Gi` |
| Gateway producer | Kafka native queue 64 MiB、2 GiB disk/block | 与 VVG 相同的 Kafka 批次和交付语义 | 公开模板 1 GiB |
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
