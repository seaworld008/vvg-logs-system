import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const dashboardPath = resolve(
  root,
  "docker-compose/grafana/routes/gateway-clickhouse/dashboards/gateway-observability.json",
);
const dashboard = JSON.parse(readFileSync(dashboardPath, "utf8"));
const text = JSON.stringify(dashboard);
const panelText = JSON.stringify(dashboard.panels ?? []);
const ipv4Addresses = text.match(/\b\d{1,3}(?:\.\d{1,3}){3}\b/g) ?? [];
const safeExampleIp = /^(?:192\.0\.2|198\.51\.100|203\.0\.113)\./;
const datasourceUids = new Set();

function collectDatasourceUids(value) {
  if (Array.isArray(value)) {
    value.forEach(collectDatasourceUids);
    return;
  }
  if (!value || typeof value !== "object") return;
  if (value.datasource?.uid) datasourceUids.add(value.datasource.uid);
  Object.values(value).forEach(collectDatasourceUids);
}

collectDatasourceUids(dashboard.panels);
const variables = new Map(
  (dashboard.templating?.list ?? []).map((variable) => [variable.name, variable]),
);

const checks = [
  [dashboard.uid === "vvg-clickhouse-gateway", "stable Dashboard UID"],
  [dashboard.title === "Gateway 请求日志分析", "default KubeDoor Gateway title"],
  [dashboard.time?.from === "now-15m", "15 minute default range"],
  [dashboard.refresh === "", "automatic refresh disabled by default"],
  [dashboard.editable === false, "provisioned dashboard is immutable"],
  [dashboard.panels?.length === 65, "complete 65-panel KubeDoor dashboard"],
  [
    [...datasourceUids].every((uid) => ["gateway-clickhouse", "__expr__"].includes(uid)),
    "stable ClickHouse datasource UID",
  ],
  [/LIMIT\s+500\b/i.test(panelText), "bounded request details"],
  [variables.get("project")?.current?.value === "gateway_access", "safe default ClickHouse table"],
  [variables.get("server_ip")?.allValue === "1 = 1", "bounded gateway All predicate"],
  [variables.get("domain")?.allValue === "1 = 1", "bounded domain All predicate"],
  [(dashboard.panels ?? []).filter((panel) => panel.type === "geomap").length === 2, "complete GeoIP map panels"],
  [dashboard.links?.some((link) => link.title === "IP Geolocation by DB-IP" && link.url === "https://db-ip.com"), "DB-IP attribution link"],
  [ipv4Addresses.every((address) => safeExampleIp.test(address)), "no non-example IPv4 addresses"],
  [!/[a-z0-9.-]+\.cn\b/i.test(text), "no production .cn domains"],
  [!text.includes("myhuaweicloud.com"), "no Huawei Cloud download links"],
];

let failed = false;
for (const [condition, description] of checks) {
  if (condition) console.log(`PASS: ${description}`);
  else {
    console.error(`FAIL: ${description}`);
    failed = true;
  }
}

if (failed) process.exit(1);
