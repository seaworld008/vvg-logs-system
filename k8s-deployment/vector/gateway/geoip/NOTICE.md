# GeoIP 数据声明

本方案使用 DB-IP City Lite `2026-09` MMDB，文件名为
`dbip-city-lite-2026-09.mmdb`，由仓库的固定 GitHub Release 资产提供：

```text
https://github.com/seaworld008/vvg-logs-system/releases/download/geoip-dbip-city-lite-2026-09/dbip-city-lite-2026-09.mmdb
```

- 发布日期：2026-09-01
- 解压后大小：127,339,927 bytes
- SHA-256：`05a10861259c7966cb54d7181ef8c360de8c8829d182098c0e62a9b7d54cd50d`
- 数据库类型：`DBIP-City-Lite`
- 授权：[Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)
- 数据来源：[IP Geolocation by DB-IP](https://db-ip.com)

Vector 节点只在本地文件不存在或 SHA-256 不匹配时下载，校验成功后再原子替换。
升级数据库必须创建新的月份 Release、更新文件名和校验值，并在 Vector `0.58.0`
上验证城市、省份、国家和经纬度字段。禁止使用浮动 `latest` URL，也不要恢复到现场云存储链接。

Dashboard 中展示或使用地域数据时必须保留 `IP Geolocation by DB-IP` 链接。
