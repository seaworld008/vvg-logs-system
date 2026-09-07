# 网大APP与老教务PHP的文件格式规则

本规则只用于 Compose 主机采集，不修改 CCE 的采集配置。规则位于
`scripts/render-host-log-collector.py` 和 `docker-compose/vector/host-automq/producer.yaml`。

## 来源与边界

迁移中对两个项目的 Java、PHP、CLI 和数据库文本来源检查了 153 个原始文件、约
6 万物理行。真实样本只用于目标机之外的受控临时分析与隔离回放，不进入仓库。
回归测试使用无业务数据的同结构样本。

| 类型 | 开始与结束 | 正文处理 |
| --- | --- | --- |
| Java 日期日志 | 完整日期时间开头，下一日志头或 3 秒空闲结束 | 异常类、Caused by、Suppressed、缩进堆栈保留在同一事件 |
| Java JSON | 行首日志 JSON 包装，下一日志头或空闲结束 | 优先用 JSON 解析器取 message；包装外堆栈接回正文 |
| 旧 Logback message 包装 | 已确认的单 message 包装，可能含未转义引号/换行 | 只在正常 JSON 解析失败后剥离这个已知包装，保留原始正文和外部堆栈；记录 parse_status |
| ThinkPHP 请求块 | 方括号完整时间开头，下一请求头/分隔线/空闲结束 | 同一请求下的 SQL、XML、错误和调试段保留上下文；级别取块中声明的最高严重程度 |
| PHP CLI | 完整时间开头，下一日志头或空闲结束 | 保持一次输出的多行正文，不跨文件合并 |
| PHP 独立 XML、数组、字符串导出 | 列首 XML/数组/带内容的单引号起始行 | 嵌套且缩进的 array 不当作新头；无可靠时间的导出保留采集时间 |
| PHP SQL 文件 | 完整日期时间开头 | 通过明确的 SQL 来源类型保留语句上下文，未声明级别时不捏造严重级别 |

只含至少 5 个 `-` 或 `=` 的分隔线和空白不作为业务事件。分隔线是 PHP 请求块的
边界，清理后通过独立 `drop_formatting_noise` 组件过滤，其 intentional counter 应
单独解释，不能等同于异常丢日志。行内横线、负数、正文中的 SQL/JSON/XML 不受此规则影响。

不按固定行数截断或拆段，9,000 行 Java 堆栈仍是一条事件。空闲超时不能重建跨很长
间隔写入的上下文，也不能把多个无时间、无关联 ID 的独立输出猜成同一个请求。
极端大记录继续受已声明的字节大小边界约束，并显式标记截断。

## 目录与服务

PHP 的 `service` 和兼容 `container` 统一以 `php_` 开头，例如 `php_jxgl`、
`php_jxgl-ptlndx`、`php_activityadmin`。Java 服务名不添加该前缀。

每个已经确认的日志根目录使用递归模式：

```yaml
include:
  - /data/apps/example/runtime/log/**/*.log
  - /data/apps/example/runtime/log/**/*.jsonl
  - /data/apps/example/runtime/log/**/*.ndjson
mounts:
  - /data/apps/example/runtime/log
```

覆盖日志根目录的直接文件和任意深度子目录。新增日期、类型、年份等子目录无需
手工修改层级通配符。日志根目录通过完整 runtime 盘点确认；不对整个 runtime 做
高频通配扫描，避免把 session/cache/temp 和业务文件一并读入或反复遍历。

盘点曾发现某 runtime 内有大量会话文件，以及 push 目录中的 `.txt` 文件。检查实际
业务函数后确认这些 txt 是推送收件账号批量文件，不是日志；因此明确排除。文件扩展名
看起来像文本不代表可以当作日志采集。未来增加日志根目录时先确认所有权、用途、格式
和敏感字段，再补入 inventory；不能一概使用 `runtime/**/*`。

## 验证

隔离回放必须验证：纯分隔线为零，已知 Java message 包装正确剥离，嵌套数组未拆散，
XML 未拆为标签碎片，服务和文件之间没有合并，所有正常正文在 `_msg` 中可搜索。
单元和容器回归另外覆盖深层日志目录、PHP 前缀、跨文件隔离、重启 checkpoint、日志
轮转、脱敏与长堆栈。变更清单前后 source ID、fingerprint 和持久化 state 保持一致。

上线后以 source offset、指标、实际项目日志和受控唯一探针确认新路径。新增匹配的
历史文件在本次允许少量丢失的迁移窗口设置一次性 EOF；日常重启和新日志轮转均从
持久化 checkpoint 或新文件开头继续，禁止每次部署都跳到 EOF。
