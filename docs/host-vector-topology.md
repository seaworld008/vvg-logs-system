# 主机日志 Vector 拓扑

## 环境策略

阿里云测试环境不使用 AutoMQ。每台主机运行一个 Vector 进程，所有已批准的日志目录作为独立 file source，经过统一的多行合并、脱敏和字段规范化后直接写入测试 VictoriaLogs。项目字段仍区分 `wangda-app` 与 `legacy-php`，消费者不参与测试链路。

华为云生产环境使用 AutoMQ。采集端可以在主机上合并为一个 Vector 进程，但必须保留每个 source 的稳定 ID、fingerprint 和 checkpoint，并按项目路由到独立 Topic；两个项目各保留一个消费者。若生产 Kafka ACL 要求每个项目使用独立 producer 身份，则应保持两个 Vector Compose 实例，避免在一个进程内复用权限。只有在 AutoMQ 为同一 Vector 提供安全的项目级路由凭据后，才合并为单进程。

## 当前测试主机结论

广西测试日志目录已纳入 `legacy-php` 的递归采集，服务名为 `php_jxgl-guangxi`。网大官网 PHP 使用 `php_wslndx-web`，与网大 APP 后台的项目归属分开。广西政务云生产日志不纳入采集范围。

合并 Vector 前先保留现有 Compose 和 state 目录作为回滚副本；切换时不得重置 checkpoint，也不得让新旧采集器同时运行。切换后至少观察日志时效、source 错误、buffer、内存和重启次数，再删除旧实例。
