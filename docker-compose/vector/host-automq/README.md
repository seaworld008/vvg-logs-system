# Compose 主机日志 -> AutoMQ -> VictoriaLogs

本目录是传统 Java/PHP 文件日志的独立采集路线。现有 Kubernetes VVG/Gateway 清单、
AutoMQ Broker 和原消费者不由本路线覆盖。所有新增组件使用 Vector `0.58.0-alpine`。
主机之间只共享版本与配置生成逻辑，不共享 checkpoint 或 buffer。

```text
Java / PHP 文件 -> Vector file source -> logs.<环境>.<项目>.v1 -> 项目 consumer -> VictoriaLogs
```

## 项目与字段

完整命名、分区、账号及标签约定见[日志项目规范](../../../docs/log-project-naming-and-labels.md)。
原始格式、业务多行边界与目录排除见[主机日志格式规则](../../../docs/host-log-format-rules.md)。
源清单明确记录旧索引、服务、文件路径、只读挂载和稳定 source ID。分类由
`scripts/render-host-log-collector.py` 统一生成：

| 原索引前缀 | project / cluster | Dashboard 名称 |
| --- | --- | --- |
| `jxgl-ptlndx*`、`php_jxgl_log*` | `legacy-php` | 老教务系统php |
| 其他 Java / PHP | `wangda-app` | 网大APP |

`php_jxgl-pay-and-more_log*` 不属于两个例外。不要用宽泛 `jxgl*` 规则替代。
老教务后台和 API 统一使用 `php_jxgl`；莆田后台和 API 统一使用 `php_jxgl-ptlndx`。
后台参考 `legacy-admin.inventory.example.yaml`，共享 API 日志参考
`legacy-api.inventory.example.yaml`。同一 NFS 文件只采集一次，不能把采集主机标签当作写入实例。
`container` 是服务名，`pod` 是稳定主机名，`namespace` 是 `java/php/text` 类型；
`file` 和 `source_offset` 保留排查定位。业务事件不能覆盖生成器指定的项目标签。

## 目录与镜像

每台采集机部署在 `/data/vector/`，其中所有新增持久化都相对于 Compose 所在目录：

```text
/data/vector/
  compose.yaml
  .env
  inventory.yaml
  image-lock.json
  SHA256SUMS
  config/vector.yaml
  secrets/password
  state/
  backups/
```

消费者按项目使用独立目录和 Compose project，例如 `vector-wangda-app-consumer`，结构相同。若真实数据盘
挂载在 `/datadisk`，可在该数据盘创建消费者目录，再通过 `/data/vector-host-consumer`
软链接提供统一入口。正式项目消费者分别使用 `vector-wangda-app-consumer` 和
`vector-legacy-php-consumer`，指标端口互不重叠。不要为了目录名称把新持久化放到空间不足的系统盘。

正式镜像优先使用组织 Harbor 的精确 tag 与已验证 digest。启动前拉取并核对镜像 ID，
正式启动不依赖在线下载。旧 Docker 或仓库 TLS/认证入口不兼容时，从受控发布主机
导出已经验证的 Harbor 镜像，传输后检查归档 SHA-256 和 `docker image inspect` 的 ID。
离线 load 可能不恢复 RepoDigests，此时使用 Harbor 精确 tag，另外把源 digest、镜像 ID、
归档校验值写入目标机 `image-lock.json`；维护前仍需核对 ID。不要关闭证书校验或修改
Docker daemon 来绕过仓库错误。

`.env`、凭据、真实清单、镜像锁和备份只存目标主机，目录 `0700`、秘密文件 `0600`。
源码仓库只保存脱敏示例。Vector 只挂载日志目录，不挂 Docker socket 或整个宿主机根目录。

## 渲染与首次迁移

生成器依赖仓库固定的 PyYAML，操作机使用 Python 3。示例命令：

```bash
python3 scripts/render-host-log-collector.py inventory.yaml /tmp/host-candidate --initial-tail
python3 scripts/render-host-log-collector.py inventory.yaml /tmp/host-steady
python3 scripts/render-host-log-collector.py consumer /tmp/consumer-candidate --project wangda-app
```

候选 `vector.yaml` 放入部署目录的 `config/vector.yaml`，`compose.yaml` 放在部署目录。
密码通过 Vector directory secret 的 `secrets/password` 加载。消费者另设
`AUTOMQ_CONSUMER_GROUP=vmlogs.prod.wangda-app.v1`（PHP 老教务使用其项目 ID）、独立用户名和正确的 VictoriaLogs 租户。
使用目标机器自己的 Compose 版本展开配置并执行 `vector validate --no-environment`。

由既有 AutoMQ 管理身份运行 `bootstrap-project.sh PROJECT ENV PARTITIONS`，创建
`logs.prod.wangda-app.v1`（6 分区）和 `logs.prod.legacy-php.v1`（3 分区）：72 小时 retention、4 MiB
消息上限、单节点 replication factor 1。每个项目的生产者只获自己 Topic 的 Write/Describe 和
IdempotentWrite；消费者只获该 Topic 的 Read/Describe 和固定 group 的 Read。
不复用管理账号，不更改现有 Topic、ACL 或 Broker 资源。

1. 盘点所有旧索引及其真实来源，至少跨 7 天覆盖低频服务；按 Filebeat 启用清单、
   应用真实文件和容器日志挂载逐项核对。额外 PHP 站点使用自己的明确日志目录。
2. 保存 Filebeat 配置、版本、service unit、可执行文件和 registry 的回滚归档及 SHA-256。
3. 先启动独立消费者，然后在一台 Java、一台 PHP 主机启动 `--initial-tail` 候选。
4. 验证输入、发送、真实 Kafka offset 和项目日志的 `_time`，再逐机切换。
5. `read_from: end` 只用于这次允许少量日志丢失的迁移窗口，不能长期使用，否则新建
   日志文件首次被发现时已写入的前段也会被跳过。
6. 初始发现后优雅停止这个 Vector。保存它生成的 `version: "1"` checkpoint，再为
   尚无 checkpoint 的既有文件记录一次 EOF 迁移位置；已有确认位置保持不变。
   `scripts/seed-vector-tail-checkpoints.py` 只支持本次验证过的 `dev_inode` 格式，并拒绝
   修改运行中容器的 checkpoint。目标缺 Python 3 时在操作机解析 JSON，通过 SSH 查询
   目标文件 device/inode/size，再上传候选并原子替换；不能用操作机文件系统的 stat。
7. 改用长期候选 `read_from: beginning`，保留同一 source ID、fingerprint 和 state 目录。
   后续新文件从开头读取，已确认旧文件从 checkpoint 恢复。这个一次性 EOF 操作不用于
   日常重启、版本升级或故障恢复。
8. 每台至少观察 15 分钟，包括轮转、错误/丢弃计数、buffer、入库时效、内存和重启。
   确认新链路可用后停止、禁用并卸载该机的 Filebeat 包，回滚归档继续保留。

旧 Elasticsearch、Logstash、Kibana 和日志 Redis 的停止/删除属于单独退役步骤。
没有完成所有来源核对前，不能因为某个 Redis list 暂时为空就删除旧服务或历史数据。

## 长期运行边界

- 采集端 1 CPU / 512 MiB；每进程 2 GiB disk/block buffer、64 MiB Kafka native queue。
- 消费者 1 CPU / 768 MiB；memory/block 64 events、2 个在途请求、Kafka offset 持久重放。
- 120 秒优雅停止；容器自身日志最多 `20 MiB x 3`。监控入口只绑定 loopback 或批准的内网。
- Java/PHP 按日志头和 3 秒空闲超时合并，正常 9,000 行堆栈不按行数拆分。
- 物理行超过 16 MiB 受 file source 上限约束。序列化正文超过 1,500,000 字节时显式
  标记 `truncated`，保存原正文大小和脱敏正文摘要，并仅保留有界前段；不能宣称超大
  日志无损。截断不做采样，不影响其他正常事件。
- Token、密码、认证头、手机号和身份证模式在 Kafka/OBS 持久化前脱敏。规则不能覆盖
  任意业务自定义秘密字段；新增格式时应补充测试并检查脱敏后样本。
- `read_from`、source ID、fingerprint 和 state 属于同一恢复契约，不能随意重置。
- Broker 不可达时依靠本地磁盘缓冲；监控其余量和最老积压。磁盘缓冲满后背压，源文件
  若被应用提前删除仍可能丢日志。当前 AutoMQ 是受控单节点部署，不是高可用集群。

至少监控 collector/consumer up、错误与丢弃增量、buffer bytes、producer 发送速率、
Kafka committed/end offset 的真实 lag、消费者内存、磁盘余量和后端最新业务时间。
维护 Broker 后必须核对真实 offset 和后端新日志，不仅查看容器 Running。

跨网段不允许中心拉取指标时，可在 inventory 设置 `metrics.mode: push`，并在 `.env`
配置组织既有的 `METRICS_REMOTE_WRITE_URL`。Vector 每 15 秒通过 Prometheus Remote Write
主动上报，使用有界独立 memory 队列，不改变日志的 Kafka disk buffer，也不增加消费者。
按需设置 `metrics.instance/ident` 与已有主机监控身份对齐；中心删除这些主机重复且不可达
的 scrape target。检查主动上报序列的时间新鲜度，不能把不再执行的拉取检查当作主机 down。

## 校验与回滚

```bash
python3 -m unittest discover -s scripts/tests -p test_host_log_collector.py -v
python3 scripts/test-host-log-runtime.py
node scripts/render-vvg-message-filter.mjs
node scripts/validate-vvg-message-filter.mjs
bash scripts/validate-configs.sh --static
git diff --check
```

真实 Vector 测试覆盖 9,000 行正文逐字节保存、新文件轮转、脱敏与重启后 checkpoint。
回滚单台采集时先恢复已保存的 Filebeat 可执行文件、配置和 unit，再停止该机 Vector；
消费者继续排空已经进入 Kafka 的消息。保留 state、Topic、凭据和旧日志归档，避免
回滚时不可恢复地删掉缓冲数据。重新启用 Filebeat 可能重复部分日志，应如实记录时间窗。
