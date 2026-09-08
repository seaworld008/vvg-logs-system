# 主机 PHP 日志历史补采

适用于首次迁移曾接受历史丢失、后来要求补齐原始文件的情况。先读
[主机迁移实践](host-log-migration-lessons.md)和[格式规则](host-log-format-rules.md)。
历史补采与日常自动发现是两个操作，不能用清空常驻 Vector state 代替补采。

## 先区分遗漏与未回放

- 从实际容器挂载与 `sources` 确认每个日志根目录，递归统计文件、扩展名、大小和日期。
- `runtime/log/**/*.log` 是 Vector 的 glob，不是正则；覆盖根目录和任意深度子目录，
  不固定日期和文件名。现场 `.log` 结尾的日期文件、`epoch-DD_cli.log` 等轮转文件都匹配。
- `read_from: beginning` 仅决定未识别的新文件读取起点，已有 device/inode checkpoint
  优先。因此首次迁移初始化到 EOF 的历史内容不会在普通重启时自动补齐。
- 对比每个文件的 device/inode、checkpoint 和大小；持续写入文件允许小的瞬时尾差。
  后端按项目、文件查询最早日志时间及最小 `source_offset`，再决定缺少哪段字节。
- 已经存入的深层日志在最近 15 分钟没有新写入时不会显示。历史验收必须选择相应日期。

日常保留 source ID、fingerprint、state 和 recursive include。公平读取用
`oldest_first: false`、发现间隔 1 秒；不要按固定文件名登记，也不要扩成整个 runtime。
rename/create 轮转依靠设备/inode 区分新旧文件，保留旧句柄的 `rotate_wait_secs`。
如果未来改成 `.log.1` 等非 `.log` 后缀，再根据实际轮转规则补受控 glob，并验证去重；
不能为了假设的格式采集缓存、临时文件或重复读取压缩副本。

## 保留期先于回放

读取当前 VictoriaLogs 的实际 `retentionPeriod`。超出保留期的事件会在写入时被拒收，
不能将其时间改成当前时间来绕过。若用户要求更早历史，需要单独确认共用库保留期的
影响或独立历史库。没有批准时不重启后端或改其他项目的保留策略。

本次用户选择沿用 180 天，只补仍在保留范围内的历史。边界日按事件时间过滤；无时间的
独立输出以已核实的文件日期（Asia/Shanghai 零点）作为估计，标记 `time_source=file_date`。
这种记录不具备精确时分秒，不能声称恢复了原事件时间。

## 有边界的只读副本

1. 保存常驻 Compose、配置、镜像 ID、读取位置和服务启动时间。清单与快照仅在目标机
   私有目录保存，目录 `0700`、配置 `0600`、快照 `0400`，生成 SHA-256 清单。
2. 对已经入库的文件，补采副本截止于最早入库事件的 `source_offset`，不包含该事件。
   对无入库记录的迁移前文件，以已核实的迁移位置/文件大小为边界。记录采样时间和
   device/inode，复制前拒绝 inode 变化、文件变短或无法解释的位置。
3. 复制指定字节前缀，保留完整日志边界。副本保留原目录结构，在补采容器中仍挂载为
   原日志路径，这样 `file/source_offset` 可以与原文件对照。禁止与实时 state 共用。
4. 首先验证边界附近正文与多行事件，确认没有重复或缺少一段。若最早入库记录的 offset
   缺失、历史已经部分重放或旧日志曾被拒收，必须明确修订计划，不能假装已精确去重。
5. 常驻采集器继续自动读取新增文件。补采实例只看冻结副本，不跟随实际业务文件增长。

`scripts/render-host-log-backfill.py` 复用已读取的 live config 生成补采 Vector YAML。
它保留解析、脱敏、标签和 Kafka 交付配置；仅保留指定 file sources，新增日期回退、
保留期过滤和非流字段 `backfill_run`。它不负责自动推断缺失范围或操作生产文件。

```bash
python3 scripts/render-host-log-backfill.py live-vector.yaml replay-vector.yaml \
  --source php_source --run-id php-history-reviewed \
  --earliest 2026-03-12T08:00:00Z
```

示例日期不能照抄；使用执行时批准的实际窗口。当前日期识别涵盖 ThinkPHP 的
`YYYYMM/DD.log`、`DD_cli.log`、`epoch-DD_cli.log`、`nocallback_DD.log`；无法识别的
历史文件先核对命名与正文，不悄悄丢弃或当成当前日志。常驻递归发现不受这个日期解析器限制。

## 运行与完成条件

- 独立 Compose project、state、metrics 及有界 disk/block buffer，镜像复用已验证版本。
  一次性进程 `restart: no`，设置 CPU、内存与 Swap 边界；本次经用户批准使用最多
  1 CPU / 1 GiB 和 1 GiB disk buffer。512 MiB 在连续历史回放时曾触发 OOM，不能把
  平时低占用当成高峰预算。保留 state 和 disk buffer 恢复，并单独核对中断前后的入库。
  大量旧文件用 `oldest_first: true` 限制同时活跃文件，只用于补采。
- 使用目标机实际 Compose 与同版本 Vector 校验，先做隔离文件回放。不要重置 Kafka
  正式 consumer group，不增加第二个常驻项目消费者。
- 验收不只看 checkpoint：所有副本读至末尾、multiline/transform 排空、Kafka 已确认
  发送、disk buffer 归零、正式 consumer committed/end offset 追平，后端已按运行标记
  可查。正常重启补采实例应从独立 checkpoint 续读，不能重头再灌。
- 按服务、文件和时间抽样 `_msg`，用正文片段再次搜索；区分空白/分隔线过滤、窗口外
  过滤与异常丢弃。复用的既有单行和超大事件限制仍有效，截断计数应单独说明。
- 记录实时采集器、后端、其他容器未重启，新日志时效、内存、错误与真实 lag。
- 确认完成后优雅停止一次性容器，保存摘要、配置、checksum 和断点，明确标记已完成，
  防止以后误启动重复补采。冻结副本不作为长期第二套日志存储。

## 回归

```bash
python3 scripts/test-host-log-backfill.py
python3 scripts/test-host-log-runtime.py
bash scripts/validate-configs.sh --static
```

真实 Vector 回归覆盖深层路径、日期轮转命名、多行、文件 offset、无时间日期回退、
窗口外过滤与重启不重复。长期 include、source ID 和 state 不因回放工具改变。
