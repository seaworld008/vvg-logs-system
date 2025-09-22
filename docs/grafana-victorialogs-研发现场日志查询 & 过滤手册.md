# Grafana × VictoriaLogs
# 研发现场日志查询 & 过滤手册（可直接替换使用）

> 适用：Grafana **Explore** 页面或面板，数据源选择 **VictoriaLogs**。  
> 目标：研发同学**快速定位问题**，把查询直接复制替换即可用。

---

## 0. 入门三步（新同学先照做）
1. 右上角选时间范围：`Last 5m / 1h / 6h / 24h`（时间范围越窄越快）。  
2. 选择数据源：**VictoriaLogs** → 选择 **Logs** 视图（不是 Table）。  
3. 在查询框粘贴下方任意示例，**改变量**后回车即可。

---

## 1. 基础语法（看这节就够用了）
- **全文匹配**（默认字段是 `_msg` 一整行）：
  ```
  "keyword"                          # 包含关键字
  _msg: "keyword"                    # 同上
  _msg: ~ /reg?ex/                   # 正则匹配
  ```
- **按字段过滤**（字段名随你们日志结构而定，下文给常见字段表）：
  ```
  status: "500"                      # 等于
  status !: "200"                    # 不等于
  responsetime_ms >= 2000            # 数值比较
  path: ~ /\/api\/v1\/users\/\d+/    # 字段正则
  ```
- **逻辑组合**：
  ```
  ( "error" or "exception" ) and not path: "/health"
  ```
- **管道写法**（便于连写，多人习惯）：
  ```
  * | "keyword" | status: "500" | not path: "/health"
  ```

> 提示：文本建议用引号；正则可用 `/.../` 或 `"...regexp..."`。

---

## 2. 你可能用到的字段（建议统一）
| 分类 | 字段名（示例） | 说明 |
|---|---|---|
| 通用 | `timestamp`, `host`, `file`, `service`, `instance`, `env` | 时间/主机/文件/服务/实例/环境 |
| HTTP | `http.method`, `status`, `path`, `query`, `protocol`, `bytes_sent`, `user_agent` | 请求方法/状态码/路径/查询等 |
| 性能 | `responsetime_ms`, `upstreamtime_ms` | 耗时（毫秒）/后端耗时 |
| 客户端 | `client_ip`, `client_city`, `client_latitude`, `client_longitude` | 客户端信息 |
| 业务 | `user_id`, `tenant_id`, `app_id`, `trace_id`, `order_id` | 业务标识 |
| 原始 | `_msg` | 原始整行消息（任何情况下都在） |

> 如果你看不到这些字段，说明日志还没结构化。优先在 **Vector** 侧解析字段，查询会更简单。

---

## 3. 常见场景（复制→替换变量→回车）

> 变量说明：`$api` 表示 API 路径，`$ip` 表示 IP，`$svc` 表示服务名等。使用时请替换为实际值。

### 3.1 关键字定位（最常用）
```
"timeout"
"OutOfMemoryError"
_msg: ~ /bmxt_.+_weektime/
```

### 3.2 查 5xx（服务器错误）
```
status: "500" or status: "502" or status: "503" or status: "504"
# 或管道：
* | status: "500" or status: "502" or status: "503" or status: "504"
```

### 3.3 慢请求（> 2s）
```
responsetime_ms >= 2000 and not path: "/health"
```

### 3.4 指定接口 + 非 2xx
```
path: "$api" and status !: "200"
# 例如：path: "/api/v1/orders/create" and status !: "200"
```

### 3.5 指定方法 + 过滤预检（OPTIONS）
```
http.method: "POST" and not http.method: "OPTIONS"
```

### 3.6 只看某个服务/实例/主机
```
service: "$svc" and host: "$host"
# 例如：service: "gateway" and host: "k8s-master3"
```

### 3.7 只看某个日志文件
```
file: "/var/log/nginx/**/access.log"
```

### 3.8 指定用户/租户/Trace
```
user_id: "$uid" and ( "error" or "exception" )
trace_id: "$trace"
tenant_id: "$tid" and status !: "200"
```

### 3.9 SQL 相关排查
```
# 任何 SQL 线索
_msg: ~ /SQL|SELECT|UPDATE|INSERT|DELETE/

# SQL 慢（结合耗时字段）
_msg: ~ /SQL/ and responsetime_ms >= 1000
```

### 3.10 排除噪音（健康检查/静态资源）
```
not path: "/health" and not path: ~ /(\.css|\.js|\.png|\.ico|\.svg)$/
```

### 3.11 组合条件（接口 + 慢 + 错误词）
```
path: "$api" and responsetime_ms >= 1500 and ("timeout" or "exception" or "stack")
```

### 3.12 指定客户端来源
```
client_ip: "$ip"
client_city: "厦门"
```

### 3.13 只看 Nginx 访问日志 + POST + 5xx
```
service: "nginx" and http.method: "POST" and status: "500"
```

### 3.14 只看网关日志 + 下游 502
```
service: "gateway" and status: "502"
```

### 3.15 正则抓接口分组（REST 风格）
```
path: ~ "^/api/v1/(orders|users|classes)/"
```

### 3.16 关键词高亮（像 grep）
1) 先执行查询（任意上面的过滤）；  
2) 在日志列表面板上方 **🔍 搜索框**输入：`关键词`，即可**黄色高亮并可跳转**。

---

## 4. 进阶技巧（10 分钟掌握）

### 4.1 管道连写（可读性强）
```
* | service: "gateway" 
  | path: "/api/v1/classes/getNowTeachingPlan" 
  | not http.method: "OPTIONS" 
  | status !: "200"
```

### 4.2 范围/区间
```
responsetime_ms: [500 TO 5000]
```

### 4.3 组合模板（复制后只改变量）
- **慢请求模板**
  ```
  ($service) and (responsetime_ms >= $rt) and not path: "/health"
  # 例：service: "nginx" and responsetime_ms >= 1200 and not path: "/health"
  ```
- **接口异常模板**
  ```
  service: "$svc" and path: "$api" and status !: "200"
  ```
- **用户问题模板**
  ```
  user_id: "$uid" and ("error" or "exception" or "timeout")
  ```

### 4.4 Table 视图看字段
- 切换到 **Table**，能看到每条日志的字段列名，方便确定究竟是 `method` 还是 `http.method`。

### 4.5 Split 分屏对比
- 点击 **Split**，左边过滤“出问题实例”，右边过滤“正常实例”，并排比对。

### 4.6 实时尾部
- 点 **Live** 开关，实时滚动查看新日志（调试期非常好用）。

---

## 5. 查询变“图表”的思路（面板）
> 需要汇总趋势/分布时使用面板而非 Explore。

- **请求量趋势**：选择 `Time series`，聚合用 `Count`。  
- **状态码分布**：`status` 分组做 `Bar/Pie`。  
- **Top Path/IP**：`Group by path` 或 `client_ip`，计算 `Count`，显示为 `Table/Bar chart`。

> 如果需要 P90/P95 响应时间曲线，建议在采集侧（Vector）派生指标或把时长单独写入时序库。

---

## 6. 常见问题（2 分钟排错）
1. **查不到**：先缩小时间；确认字段名拼写；Table 里看真实字段名。  
2. **慢**：时间窗太大/条件太宽；先限定 `service/host/file` 再放宽。  
3. **没高亮**：那是本地搜索功能，执行查询后在日志面板**🔍**里输入关键词即可。  
4. **长行看不全**：打开 **Wrap lines**；或切到 Table 看字段。  
5. **重复很多**：可以开 **Dedup** 去重；若要看全部先关闭它。

---

## 7. 速查卡（贴在工位边上）
```
包含词：           "error"              或   _msg: "error"
正则：             _msg: ~ /timeout|timed out/
字段等于/不等于：  status: "500"       /    status !: "200"
数值比较：         responsetime_ms >= 2000
组合：             http.method: "POST" and status !: "200"
排除噪音：         not path: "/health" and not path: ~ /(\.css|\.js|\.png|\.ico)$/
限定范围：         host: "k8s-master3" | service: "nginx" | file: "/var/log/nginx/**/access.log"
管道连写：         * | "keyword" | status: "500" | not path: "/health"
高亮：             执行后，在日志列表的 🔍 输入要高亮的词
```

---

> 需要我把你们项目常用的接口/字段做成可复用的“查询模板库”（点一下就换变量）吗？发我一份字段清单即可，我来补充成一套团队级文档。
