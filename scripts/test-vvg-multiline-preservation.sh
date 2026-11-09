#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
container="vvg-multiline-preserve-${RANDOM}-${RANDOM}"
cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT
mkdir -p "${work_dir}/state"
python3 - "${repo_root}" "${work_dir}" <<'PY'
import copy, json, pathlib, sys, yaml
root, work = map(pathlib.Path, sys.argv[1:])
docs = yaml.safe_load_all((root / "k8s-deployment/vector/vvg/direct-containerd.yaml").read_text())
cm = next(d for d in docs if d and d.get("kind") == "ConfigMap")
reduce = copy.deepcopy(yaml.safe_load(cm["data"]["vector.yaml"])["transforms"]["enhance_multiline"])
assert "max_events" not in reduce and "end_every_period_ms" not in reduce
# Nginx/combined access-log lines start with IPv4 and must start a new event;
# otherwise continuous traffic is merged into one oversized record.
assert r"\d{1,3}(?:\.\d{1,3}){3}\s" in reduce["starts_when"]
reduce["inputs"] = ["lines"]
message = "2026-01-01 00:00:00 INFO synthetic stack\n" + "\n".join(f"  java-frame-{i:05d}" for i in range(9000))
access = [f'10.0.{i}.8 - - [01/Jan/2026:00:00:0{i} +0800] "GET /health-check-{i} HTTP/1.1" 200 2' for i in range(3)]
(work / "input.log").write_text(message + "\n" + "\n".join(access) + "\n", encoding="utf-8")
(work / "expected.json").write_text(json.dumps([message] + access), encoding="utf-8")
config = {
    "data_dir": "/work/state",
    "sources": {"lines": {"type": "file", "include": ["/work/input.log"], "read_from": "beginning"}},
    "transforms": {"multiline": reduce},
    "sinks": {"out": {"type": "console", "inputs": ["multiline"], "encoding": {"codec": "json"}}},
}
(work / "vector.yaml").write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
PY
docker run -d --name "${container}" --network none \
  --user "$(id -u):$(id -g)" \
  --memory 256m --memory-swap 256m --cpus 0.5 \
  -v "${work_dir}:/work" "${VECTOR_IMAGE:-timberio/vector:0.58.0-alpine}" \
  --config /work/vector.yaml >/dev/null
for _ in $(seq 1 30); do
  docker logs "${container}" > "${work_dir}/output.log" 2>&1
  if python3 - "${work_dir}" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
rows = []
for line in (work / "output.log").read_text(encoding="utf-8").splitlines():
    try: rows.append(json.loads(line))
    except json.JSONDecodeError: pass
messages = [row["message"] for row in rows if "message" in row]
expected = json.loads((work / "expected.json").read_text(encoding="utf-8"))
raise SystemExit(0 if messages == expected else 1)
PY
  then
    test "$(docker inspect -f '{{.State.OOMKilled}}' "${container}")" = false
    printf 'PASS: 9000 Java stack lines remain one complete event, byte-for-byte; 3 access-log lines stay separate\n'
    exit 0
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "${container}")" != true ]]; then break; fi
  sleep 1
done
printf 'FAIL: 9000-line Java event not kept whole, or access-log lines were merged\n' >&2
exit 1
