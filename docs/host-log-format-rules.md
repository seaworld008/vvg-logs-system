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

PHP 的 `service` 和兼容 `container` 统一以 `php_` 开头。老教务后台和教务 API
统一使用 `php_jxgl`；莆田后台和 API 统一使用 `php_jxgl-ptlndx`，不按 admin/api 拆分。
网大后台例如 `php_activityadmin`。Java 服务名不添加该前缀。

后台和 API 都属于 `legacy-php`，共用 `logs.prod.legacy-php.v1` 以及该项目的一个消费者。
参考 `legacy-admin.inventory.example.yaml` 和 `legacy-api.inventory.example.yaml`。
服务显示名调整时保留原 source ID、include、fingerprint、state 和 checkpoint，
不能为改名重新从头读取文件。历史日志保留旧标签，新日志使用新服务名。

共享日志目录只由一个指定采集端读取。例如 API 的多台主机通过 NFS 写入同一份
runtime/log，应该在共享目录所有者处采集一次；不能在每个 NFS 客户端重复部署相同
采集。此时 `instance/pod` 表示采集主机，不能冒充实际写入容器。莆田后台和 API
共用文件时统一标为 `php_jxgl-ptlndx`；精确区分写入实例需要应用增加身份字段或使用
独立日志目录。Nginx access/error 日志按下文“Nginx 文件日志”单独声明。

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

## Nginx 文件日志

主机 Nginx 日志复用所在主机已有的采集端和项目 Topic，不新建容器、Topic 或消费者。
在 inventory 中新增一个 `format: nginx` 条目即可：

```yaml
- id: nginx_example            # 稳定 source ID，决定 checkpoint 目录
  service: nginx-example       # 与同业务 PHP 服务并列，例如 nginx-jxgl / nginx-jxgl-ptlndx
  format: nginx
  namespace: php               # 与所属业务同一 namespace，Dashboard 才会归在一起
  legacy_index: example-nginx
  include:
  - /data/apps/example/nginx_logs/access_log
  - /data/apps/example/nginx_logs/error_log
  mounts:
  - /data/apps/example/nginx_logs
```

- `format: nginx` 不配置 multiline，每行一个事件；`language` 默认为 `text`，`log_type` 默认为 `access`。
- `namespace` 默认等于 `language`（`text`）。归属某业务时必须显式填写，否则会落在 `text` 下，
  与业务 PHP 日志分开显示。
- 共享 normalize 的 `if .log_format == "nginx"` 块统一处理三种行：JSON access（`status`、
  `request_time`、`upstream_*`、`time`）、combined access（`[$time_local]` 和状态码）、
  error log（`YYYY/MM/DD HH:MM:SS [level]`，按 Asia/Shanghai 解析）。access 级别按状态码：
  5xx=error、4xx=warn、其余 info；error log 的 crit/alert/emerg 记为 critical。
- include 只写确认的 access/error 文件，不要用 `*` 带上同目录的 worker 等其他程序日志。
- 已有大文件首次接入时只对新 source 做一次 EOF 初始化：先以 `--initial-tail` 渲染上线，
  确认该 source 的每个文件都已写出 checkpoint（没有新行的文件不会写，必要时产生一条无害请求），
  再改回 `read_from: beginning` 重启；其他 source 的 state 保持不变。
- 多副本容器内 Nginx 写同一 NFS 文件时只在文件所有者采集一次；此时 `remote_addr`
  通常是前置代理地址，真实客户端需要前置 Nginx 日志或 `X-Forwarded-For`。

JSON 行没有 `message` 字段时保留整行作为正文（以前会变成空串被空行过滤丢弃）。

## 验证

隔离回放必须验证：纯分隔线为零，已知 Java message 包装正确剥离，嵌套数组未拆散，
XML 未拆为标签碎片，服务和文件之间没有合并，所有正常正文在 `_msg` 中可搜索。
单元和容器回归另外覆盖深层日志目录、PHP 前缀、跨文件隔离、重启 checkpoint、日志
轮转、脱敏与长堆栈。变更清单前后 source ID、fingerprint 和持久化 state 保持一致。

上线后以 source offset、指标、实际项目日志和受控唯一探针确认新路径。新增匹配的
历史文件在本次允许少量丢失的迁移窗口设置一次性 EOF；日常重启和新日志轮转均从
持久化 checkpoint 或新文件开头继续，禁止每次部署都跳到 EOF。
