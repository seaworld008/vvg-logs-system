import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const output = resolve(
  root,
  "docker-compose/grafana/routes/gateway-clickhouse/dashboards/gateway-observability.json",
);
const source = process.argv[2] ? resolve(process.cwd(), process.argv[2]) : output;
const datasourceUid = "gateway-clickhouse";
const dashboardUid = "vvg-clickhouse-gateway";
const pluginVersion = "4.5.1";
const sensitiveDomainSuffixes = (process.env.GATEWAY_SENSITIVE_DOMAIN_SUFFIXES ?? "")
  .split(",")
  .map((suffix) => suffix.trim().replace(/^\./, ""))
  .filter(Boolean);
const dbIpAttribution = {
  asDropdown: false,
  icon: "external link",
  includeVars: false,
  keepTime: false,
  tags: [],
  targetBlank: true,
  title: "IP Geolocation by DB-IP",
  tooltip: "GeoIP data attribution",
  type: "link",
  url: "https://db-ip.com",
};

const parsed = JSON.parse(readFileSync(source, "utf8"));
const dashboard = parsed.dashboard ?? parsed;

function sanitizeString(value) {
  let sanitized = value
    .replace(/\bnginx_access\b/g, "gateway_access")
    .replace(
      /\b(?!(?:192\.0\.2|198\.51\.100|203\.0\.113)\.)\d{1,3}(?:\.\d{1,3}){3}\b/g,
      "198.51.100.20",
    );
  for (const suffix of sensitiveDomainSuffixes) {
    const escaped = suffix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    sanitized = sanitized.replace(
      new RegExp(`[a-z0-9.-]+\\.${escaped}`, "gi"),
      "api.example.com",
    );
  }
  return sanitized;
}

function sanitize(value) {
  if (typeof value === "string") return sanitizeString(value);
  if (Array.isArray(value)) return value.map(sanitize);
  if (!value || typeof value !== "object") return value;

  const result = {};
  for (const [key, child] of Object.entries(value)) {
    result[key] = key === "pluginVersion" ? pluginVersion : sanitize(child);
  }
  if (result.type === "grafana-clickhouse-datasource" && "uid" in result) {
    result.uid = datasourceUid;
  }
  return result;
}

const normalized = sanitize(dashboard);
normalized.id = null;
normalized.uid = dashboardUid;
normalized.title = "Gateway 请求日志分析";
normalized.editable = false;
normalized.refresh = "";
normalized.time = { from: "now-15m", to: "now" };
normalized.version = 1;
normalized.tags = [...new Set([...(normalized.tags ?? []), "vector", "clickhouse", "gateway"])]
  .filter((tag) => !/jinling/i.test(tag));
normalized.description =
  "Kubernetes Gateway access logs collected by Vector, stored in ClickHouse, and visualized in Grafana.";

normalized.links = (normalized.links ?? []).filter(
  (link) => link?.title !== dbIpAttribution.title,
);
normalized.links.push(dbIpAttribution);

const variables = new Map(
  (normalized.templating?.list ?? []).map((variable) => [variable.name, variable]),
);

if (variables.has("project")) {
  variables.get("project").current = {
    text: "gateway_access",
    value: "gateway_access",
  };
}

for (const name of ["server_ip", "domain"]) {
  if (variables.has(name)) {
    variables.get(name).current = { text: "All", value: "$__all" };
    variables.get(name).includeAll = true;
    variables.get(name).allValue = "1 = 1";
  }
}

if (variables.has("status")) {
  variables.get("status").current = { text: "全部", value: "1=1" };
}
if (variables.has("uri")) {
  variables.get("uri").current = { text: "/", value: "/" };
}
if (variables.has("cip")) {
  variables.get("cip").current = { text: "", value: "" };
}
if (variables.has("cal_interval")) {
  variables.get("cal_interval").current = { text: "1m", value: "60" };
}

writeFileSync(output, `${JSON.stringify(normalized, null, 2)}\n`, "utf8");
console.log(`Sanitized ${normalized.panels?.length ?? 0} panels into ${output}`);
