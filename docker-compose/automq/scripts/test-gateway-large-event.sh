#!/usr/bin/env bash
set -euo pipefail

vector_image="${VECTOR_IMAGE:-timberio/vector:0.58.0-alpine}"
work_dir="$(mktemp -d)"
container="vector-gateway-large-event-${RANDOM}-${RANDOM}"
cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT
chmod 0700 "${work_dir}"
mkdir -p "${work_dir}/state"

python3 - "${work_dir}/input.log" <<'PY'
import json, pathlib, sys

event = {
    "requestHeaders": "{}",
    "requestBody": {
        "lines": [f"line-{index:05d}" for index in range(9000)],
        "singleLineOverDefaultLimit": "x" * 200_000,
    },
    "responseBody": {"code": 0},
}
body = json.dumps(event, ensure_ascii=True, indent=2)
pathlib.Path(sys.argv[1]).write_text(
    f"[writeAccessLog][gateway-log:{body}]\n", encoding="utf-8"
)
PY

cat > "${work_dir}/vector.yaml" <<'YAML'
data_dir: /work/state
sources:
  gateway:
    type: file
    include:
      - /work/input.log
    ignore_checkpoints: true
    read_from: beginning
    max_line_bytes: 16777216
    max_read_bytes: 65536
    multiline:
      start_pattern: '.*\[writeAccessLog\]\[gateway-log:'
      mode: halt_before
      condition_pattern: '.*\[writeAccessLog\]\[gateway-log:'
      timeout_ms: 250
transforms:
  verify:
    type: remap
    inputs:
      - gateway
    source: |
      message = string!(.message)
      parsed = parse_regex!(message, r'(?s)\[writeAccessLog\]\[gateway-log:(?P<json>\{.*\})\]')
      event = parse_json!(string!(parsed.json))
      .line_count = length(split(message, "\n"))
      .array_count = length(array!(event.requestBody.lines))
      .large_line_bytes = length(string!(event.requestBody.singleLineOverDefaultLimit))
sinks:
  output:
    type: console
    inputs:
      - verify
    target: stdout
    encoding:
      codec: json
YAML

docker run -d --name "${container}" \
  --network none \
  --user "$(id -u):$(id -g)" \
  --memory 512m --memory-swap 512m --cpus 0.5 \
  -v "${work_dir}:/work" \
  "${vector_image}" --config /work/vector.yaml >/dev/null

for _ in $(seq 1 20); do
  docker logs "${container}" > "${work_dir}/output.log" 2>&1
  if python3 - "${work_dir}/output.log" <<'PY'
import json, sys

for line in open(sys.argv[1], encoding="utf-8"):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if (event.get("line_count", 0) >= 9000
            and event.get("array_count") == 9000
            and event.get("large_line_bytes") == 200000):
        raise SystemExit(0)
raise SystemExit(1)
PY
  then
    printf 'PASS: Vector preserved and parsed the 9000-line Gateway event\n'
    exit 0
  fi
  sleep 1
done

docker logs "${container}" >&2
printf 'FAIL: Vector did not preserve the 9000-line Gateway event\n' >&2
exit 1
