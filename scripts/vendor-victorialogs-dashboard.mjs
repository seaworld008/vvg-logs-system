import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const version = "v1.52.0";
const expectedSha256 = "07a17ece43627672bdc8335a6e51a881c11ae58f184f51623094e204d84be569";
const upstream = `https://raw.githubusercontent.com/VictoriaMetrics/VictoriaLogs/${version}/dashboards/victorialogs.json`;
const root = resolve(import.meta.dirname, "..");
const output = resolve(root, "docker-compose/victorialogs/monitoring/grafana/victorialogs-v1.52.0.json");
const nightingaleOutput = resolve(root, "docker-compose/victorialogs/monitoring/nightingale/victorialogs-v1.52.0.json");

const sha256 = (content) => createHash("sha256").update(content).digest("hex");

const validate = (content) => {
  const actualSha256 = sha256(content);
  if (actualSha256 !== expectedSha256) {
    throw new Error(`VictoriaLogs dashboard SHA-256 mismatch: ${actualSha256}`);
  }

  const dashboard = JSON.parse(content.toString("utf8"));
  const allPanels = [];
  const visit = (panels) => {
    for (const panel of panels) {
      allPanels.push(panel);
      if (panel.panels) visit(panel.panels);
    }
  };
  visit(dashboard.panels);

  if (dashboard.title !== "VictoriaLogs - single-node" || dashboard.uid !== "OqPIZTX4z") {
    throw new Error("Unexpected VictoriaLogs dashboard identity");
  }
  if (dashboard.time?.from !== "now-3h" || allPanels.length !== 73) {
    throw new Error("Unexpected VictoriaLogs dashboard layout or default range");
  }
  if (!allPanels.some((panel) => panel.title === "Logs ingestion rate")) {
    throw new Error("VictoriaLogs ingestion panel is missing");
  }
  if (!allPanels.some((panel) => panel.title === "Query duration p99")) {
    throw new Error("VictoriaLogs query latency panel is missing");
  }
};

const validateNightingale = () => {
  const dashboard = JSON.parse(readFileSync(nightingaleOutput, "utf8"));
  if (dashboard.name !== "VictoriaLogs 生产监控（官方 v1.52.0 单机版）") {
    throw new Error("Unexpected Nightingale VictoriaLogs dashboard name");
  }
  if (dashboard.ident !== "victorialogs-production-monitoring") {
    throw new Error("Unexpected Nightingale VictoriaLogs dashboard identity");
  }

  const panels = [];
  const visit = (items) => {
    for (const panel of items) {
      panels.push(panel);
      if (panel.panels) visit(panel.panels);
    }
  };
  visit(dashboard.configs.panels);
  if (panels.length !== 73 || panels.some((panel) => panel.type === "unknown")) {
    throw new Error("Nightingale must preserve all 73 supported VictoriaLogs panels");
  }
  const flags = panels.find((panel) => panel.name === "Non-default flags（非默认启动参数）");
  if (flags?.type !== "barGauge") {
    throw new Error("Nightingale non-default flags panel must use barGauge");
  }
  const datasourceVariables = dashboard.configs.var.filter(
    (variable) => variable.type === "datasource" && variable.name === "DS_PROMETHEUS",
  );
  if (datasourceVariables.length !== 1) {
    throw new Error("Nightingale dashboard must contain one Prometheus datasource variable");
  }
  const dataPanels = panels.filter((panel) => panel.type !== "row");
  if (dataPanels.some((panel) => Object.hasOwn(panel.options?.standardOptions ?? {}, "util"))) {
    throw new Error("Nightingale dashboard must not use the legacy util unit key");
  }
  if (dataPanels.some((panel) => !Object.hasOwn(panel.options?.standardOptions ?? {}, "unit"))) {
    throw new Error("Every Nightingale data panel must declare a native unit");
  }
  const availableMemory = panels.find((panel) => panel.name === "Available memory");
  if (availableMemory?.targets?.[0]?.expr !== 'sum(vm_available_memory_bytes{job=~"$job", instance=~"$instance"})') {
    throw new Error("Nightingale available-memory query is missing");
  }
  const expectedUnits = new Map([
    ["Total log entries", "short"],
    ["Insert req/s", "reqps"],
    ["Disk space usage", "bytesIEC"],
    ["Request duration p99", "seconds"],
    ["Total memory % usage ($instance)", "percentUnit"],
  ]);
  for (const [name, unit] of expectedUnits) {
    const matchingPanels = panels.filter((panel) => panel.name === name);
    if (!matchingPanels.length || matchingPanels.some((panel) => panel.options.standardOptions.unit !== unit)) {
      throw new Error(`Unexpected Nightingale unit for ${name}`);
    }
  }
};

const normalizeNightingale = () => {
  const dashboard = JSON.parse(readFileSync(nightingaleOutput, "utf8"));
  const upstreamDashboard = JSON.parse(readFileSync(output, "utf8"));
  const upstreamUnits = new Map();
  const collectUnits = (panels) => {
    for (const panel of panels) {
      if (panel.title) upstreamUnits.set(panel.title, panel.fieldConfig?.defaults?.unit ?? "none");
      if (panel.panels) collectUnits(panel.panels);
    }
  };
  collectUnits(upstreamDashboard.panels);
  const unitMap = new Map([
    ["bytes", "bytesIEC"],
    ["none", "none"],
    ["percentunit", "percentUnit"],
    ["reqps", "reqps"],
    ["s", "seconds"],
    ["short", "short"],
  ]);
  const nativeUnitOverrides = new Map([
    ["Insert req/s", "reqps"],
    ["Read req/s", "reqps"],
    ["Requests rate", "reqps"],
    ["Requests error rate", "reqps"],
    ["Request rate", "reqps"],
    ["Query rate", "reqps"],
    ["TCP connections rate ($instance)", "reqps"],
    ["VictoriaLogs internal logging", "mps"],
    ["Memory allocations rate", "bytesSecIEC"],
    ["Disk writes/reads ($instance)", "bytesSecIEC"],
  ]);
  const visit = (panels) => {
    for (const panel of panels) {
      if (panel.type !== "row") {
        const standardOptions = panel.options?.standardOptions ?? {};
        if (Object.hasOwn(standardOptions, "util")) {
          standardOptions.unit = standardOptions.util;
          delete standardOptions.util;
        }
        const upstreamUnit = upstreamUnits.get(panel.name);
        if (upstreamUnit !== undefined) standardOptions.unit = unitMap.get(upstreamUnit) ?? "none";
        if (nativeUnitOverrides.has(panel.name)) standardOptions.unit = nativeUnitOverrides.get(panel.name);
        panel.options.standardOptions = standardOptions;
      }
      if (panel.name === "Available memory") {
        panel.targets = [
          {
            refId: "A",
            expr: 'sum(vm_available_memory_bytes{job=~"$job", instance=~"$instance"})',
            legend: "total",
            instant: true,
          },
        ];
      }
      if (panel.panels) visit(panel.panels);
    }
  };
  visit(dashboard.configs.panels);
  writeFileSync(nightingaleOutput, `${JSON.stringify(dashboard, null, 2)}\n`, "utf8");
};

if (process.argv.includes("--normalize-nightingale")) {
  normalizeNightingale();
  validateNightingale();
  console.log(`Normalized VictoriaLogs ${version} Nightingale dashboard units and targets`);
} else if (process.argv.includes("--check")) {
  validate(readFileSync(output));
  validateNightingale();
  console.log(`Verified VictoriaLogs ${version} Grafana and Nightingale dashboards (${expectedSha256})`);
} else {
  const response = await fetch(upstream);
  if (!response.ok) {
    throw new Error(`Unable to download VictoriaLogs dashboard: HTTP ${response.status}`);
  }
  const content = Buffer.from(await response.arrayBuffer());
  validate(content);
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, content);
  console.log(`Vendored VictoriaLogs ${version} dashboard (${expectedSha256})`);
}
