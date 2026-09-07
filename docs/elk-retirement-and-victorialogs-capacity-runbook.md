# ELK 退役与 VictoriaLogs 专用主机容量调整

本文适用于已经完成 Filebeat -> Vector -> AutoMQ -> VictoriaLogs 迁移，并且另行
明确授权停止旧 ELK、永久清理旧日志数据的场景。迁移验收不自动包含数据删除授权。
先读[主机迁移实践](host-log-migration-lessons.md)，重新核对现场，不把历史快照当作
当前服务状态。真实地址、清单、原始日志和运行快照留在受控环境。

## 1. 确认退役对象与新链路

用 `docker inspect` 的 Compose project、working directory、config files、镜像、
mounts 和 network 确定所有权。分别识别 Elasticsearch、Kibana、每个 Logstash 和
日志专用 Redis，不能用名称中有 redis/elk 就批量停止。

- 对照所有已迁移采集端，确认 Vector 运行、Filebeat 进程及包已移除、checkpoint 保留。
- 对新项目抽样核对实际正文、业务时间与服务标签，确认消息持续入库及真实 Kafka
  committed/end offset。不能只看容器 Running 或历史截图。
- 对日志 Redis 比较多个时点的生产命令计数、keyspace、客户端连接和来源。单次空
  list 不等于没有生产者；Logstash 空轮询可能仍有大量连接及 evalsha 调用。
- 检查 ES 索引类型和实际用途，区分日志索引、Kibana 系统索引与业务搜索数据。
  ES 总 indexing 计数增长也可能来自 Kibana 系统记录，不能直接认定还有日志写入。
- 检查定时任务、systemd、Compose 自动启动及反向代理。其他主机的 Kibana 或指向
  不同集群的 ES 代理需按实际后端划分，不能因名称相似扩大删除范围。

确认新旧挂载没有同目录、父子目录或共享 volume 重叠。新 VictoriaLogs 数据、Vector
state、AutoMQ 数据以及应用原始文件都不属于旧 ES 数据清理范围。

## 2. 停止、清理与验收

1. 保存小型配置和元数据归档：Compose、Logstash/Redis 配置、容器 inspect、索引
   清单及退役说明，目录 `0700`、文件 `0600`，生成并验证 SHA-256。若用户明确不要
   旧 ES 数据，不额外复制整份旧索引；记录配置归档无法恢复旧日志。
2. 将已确认的旧容器 restart policy 改为 `no`，先停 Logstash/Kibana，再优雅停止
   ES 和日志 Redis，核对退出状态。不要执行整个宿主机或共享 Compose 的 down。
3. 删除前重新核对固定 container ID、标签和停止状态。确认没有保留容器引用旧
   volume；核对旧数据根目录的 realpath、符号链接及下级挂载。
4. 仅删除核准的旧容器、专属 volume 和 ES 数据根目录。大量文件低优先级清理，
   不跨文件系统，不执行全局 Docker prune 或按通配符删除 `/data`。
5. 将旧 Compose 从活跃部署目录退役，保留归档防止误启动。确认旧网络无其他容器
   后再删除，仅移除没有被保留容器使用的旧镜像，不使用强制镜像删除。
6. 验证旧数据路径、容器、监听端口已消失，新链路持续工作；比较清理前后文件
   系统实际可用字节。可用空间差会受同期业务写入影响，不等于索引目录大小。

Nginx 等共享基础服务按明确范围处理；不能为了关闭 Kibana 而停止承载其他代理的
整个 Nginx。DNS、证书、其他搜索集群、业务 Redis 和监控 Redis 不随日志 ELK 退役。

## 3. 专用主机参考配置

原通用环境示例保留较保守的 `3 CPU / 5 GiB / 1 reader`。旧 ELK 完成清理后，
4 核、16 GiB 主机专用于 VictoriaLogs 与消费者时，可以在实际容量核算和查询
验证后采用以下配置。它不是所有环境的默认值，不可复制到小内存机器。

| 项目 | 专用主机配置 |
| --- | --- |
| VictoriaLogs 镜像、数据目录及保留期 | 保留实际已验证版本和现有值，容量调整不顺带升级 |
| CPU / 内存上限 | 3 CPU / 8 GiB |
| 内存加 Swap 上限 | 与内存同为 8 GiB，不增加 Swap |
| `search.maxConcurrentRequests` | 4 |
| `defaultParallelReaders` | 经 A/B 验证后从 1 提升为 2 |
| `search.maxQueueDuration` / `search.maxQueryDuration` | 1m / 2m |
| `search.logSlowQueryDuration` | 8s |
| `memory.allowedPercent` | 保留默认 60%，缓存预算约 4.8 GiB |
| 容器自身日志 | json-file，20 MiB x 3 |

同机三个 CCE 消费者各 1.5 GiB，两个项目消费者各 768 MiB，合计上限 6 GiB。
这些是上限，不是已分配内存；仍需核对真实 MemTotal、峰值占用、内核及其他服务
余量。不要把剩余内存全部分给 VictoriaLogs。内部缓存预算不是 RSS 或容器总内存
上限，扩大 allowedPercent 可能挤压文件缓存；本次不调整该比例。

对于已使用仓库环境变量的部署，容量相关覆盖值为：

```dotenv
VICTORIALOGS_CPUS=3.0
VICTORIALOGS_MEMORY_LIMIT=8g
VL_SEARCH_MAX_CONCURRENT_REQUESTS=4
VL_DEFAULT_PARALLEL_READERS=2
```

在真实 Compose 对应服务中另外设置 `memswap_limit: 8g` 和上述 logging 轮转。
旧 Compose 可能使用 `deploy.resources.limits`，必须在目标机展开候选并核对最终
容器的 `HostConfig.Memory/MemorySwap/NanoCpus`，不能只相信 YAML 声明。持久化
仍使用当前 Compose 目录下的独立数据子目录，不用仓库模板覆盖真实部署全部内容。

## 4. 查询验证和配置切换

先释放旧 ELK 资源，再比较读取并行度，避免把清理与参数效果混为一谈。使用固定
绝对时间窗，覆盖两个项目及 CCE 的 15 分钟统计、1 小时正文检索和 hits 趋势。
通过 `options(parallel_readers=1)` 与 `options(parallel_readers=2)` 在相同服务上
交错测试，预热后比较耗时和结果一致性；无需为了 A/B 重启服务。

小样本改善只支持当前读取档位选择，不能宣称长期 P95/P99 或高峰吞吐保证。保持
查询并发 4，不因增加内存直接扩大并发。高延迟存储更可能从多路读取获益，过多
读取线程会增加 RAM/CPU，参见[官方查询选项](https://docs.victoriametrics.com/victorialogs/logsql/#parallel_readers-query-option)
与[内存参数说明](https://docs.victoriametrics.com/victorialogs/#list-of-command-line-flags)。

归档当前 Compose、镜像 ID、挂载及容器基线，结构化比较候选仅包含批准的参数。
使用相同镜像和目标机 Compose 校验。优雅停止 VictoriaLogs 等待刷盘，只重建它，
保留数据目录。消费者保持运行，由已有重试及 Kafka offset 恢复，不重建或重置它们。
同版本配置失败时立即恢复原 Compose、相同镜像和原数据目录。

上线后执行四个并发请求模拟趋势、总数、错误数与最多 500 行明细，核对 `_msg` 与
临时 `message` 别名一致。保留至少 15 分钟观察：health、写入增长、最新业务时间、
真实 Kafka lag、查询排队超时、丢弃增量、内存余量、OOM 和重启。维护瞬间的请求
失败与恢复后的持续错误分别统计，不能把累计历史值当作本次故障。

最后保存实际 Compose 与维护 README、容量及退役结果，后续升级必须读取这一
现场配置。较早文档的 5 GiB 参考值不能覆盖已经验证并批准的专用主机配置。
