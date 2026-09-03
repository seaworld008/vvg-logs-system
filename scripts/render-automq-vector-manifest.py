#!/usr/bin/env python3
"""Render shadow or production AutoMQ producer manifests from a live Vector source."""

from __future__ import annotations

import argparse
import copy
import hashlib
import re
from pathlib import Path
from typing import Any

import yaml


class BlockString(str):
    pass


class ManifestDumper(yaml.SafeDumper):
    pass


def represent_block_string(dumper: yaml.Dumper, value: BlockString) -> yaml.Node:
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style="|")


def represent_readable_string(dumper: yaml.Dumper, value: str) -> yaml.Node:
    style = "|" if "\n" in value else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


ManifestDumper.add_representer(BlockString, represent_block_string)
ManifestDumper.add_representer(str, represent_readable_string)


PRODUCER_STALL_CHECK_SCRIPT = r"""#!/bin/sh
set -eu

state_file=/tmp/automq-producer-last-queue
metrics_url="http://127.0.0.1:${AUTOMQ_METRICS_PORT}/metrics"
broker="${AUTOMQ_BOOTSTRAP_SERVERS%%,*}"

if ! nc -z -w 2 "${broker%:*}" "${broker##*:}" >/dev/null 2>&1; then
  rm -f "${state_file}"
  exit 0
fi

metrics="$(wget -qO- -T 5 "${metrics_url}")"
queued="$(printf '%s\n' "${metrics}" | awk '
  /^vector_buffer_size_bytes\{/ && /component_type="kafka"/ {sum += $(NF-1)}
  END {printf "%.0f", sum + 0}
')"
sent="$(printf '%s\n' "${metrics}" | awk '
  /^vector_component_sent_events_total\{/ && /component_type="kafka"/ {sum += $(NF-1)}
  END {printf "%.0f", sum + 0}
')"

previous="$(cat "${state_file}" 2>/dev/null || true)"
printf '%s\n' "${queued}" > "${state_file}"

if [ "${queued}" -lt "${AUTOMQ_STALL_BUFFER_THRESHOLD_BYTES}" ]; then
  exit 0
fi
if [ -z "${previous}" ] || [ "${queued}" -lt "${previous}" ]; then
  exit 0
fi

printf 'Kafka producer not draining: queued=%s previous=%s sent=%s\n' \
  "${queued}" "${previous}" "${sent}" >&2
exit 1
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pipeline", choices=("vvg", "gateway"), required=True)
    parser.add_argument("--mode", choices=("shadow", "production"), required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vector-image", required=True)
    parser.add_argument("--bootstrap", default="192.0.2.10:9092")
    parser.add_argument("--shadow-state-suffix", default="")
    args = parser.parse_args()
    if not re.fullmatch(r"(?:-[a-z0-9]+)*", args.shadow_state_suffix):
        parser.error("--shadow-state-suffix must be empty or use lowercase dash segments")
    return args


def clean_object(obj: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(obj)
    metadata = result.setdefault("metadata", {})
    for key in ("creationTimestamp", "generation", "resourceVersion", "selfLink", "uid", "managedFields"):
        metadata.pop(key, None)
    result.pop("status", None)
    return result


def find_resource(documents: list[dict[str, Any]], kind: str, predicate: Any) -> dict[str, Any]:
    matches = [doc for doc in documents if doc.get("kind") == kind and predicate(doc)]
    if len(matches) != 1:
        raise SystemExit(f"Expected one {kind}, found {len(matches)}")
    return clean_object(matches[0])


def replace_string_values(value: Any, old: str, new: str) -> Any:
    if isinstance(value, dict):
        return {key: replace_string_values(item, old, new) for key, item in value.items()}
    if isinstance(value, list):
        return [replace_string_values(item, old, new) for item in value]
    if isinstance(value, str):
        return value.replace(old, new)
    return value


def kafka_sink(inputs: list[str], buffer_size: int) -> dict[str, Any]:
    return {
        "type": "kafka",
        "inputs": inputs,
        "bootstrap_servers": "${AUTOMQ_BOOTSTRAP_SERVERS}",
        "topic": "${AUTOMQ_TOPIC}",
        "key_field": "_automq_partition_key",
        "compression": "zstd",
        "encoding": {"codec": "json", "timestamp_format": "rfc3339"},
        "sasl": {
            "enabled": True,
            "mechanism": "SCRAM-SHA-512",
            "username": "${AUTOMQ_PRODUCER_USERNAME}",
            "password": "SECRET[automq_auth.password]",
        },
        "acknowledgements": {"enabled": True},
        "batch": {"max_bytes": 1048576, "max_events": 500, "timeout_secs": 1},
        "buffer": {"type": "disk", "max_size": buffer_size, "when_full": "block"},
        "message_timeout_ms": 0,
        "socket_timeout_ms": 60000,
        "librdkafka_options": {
            "acks": "all",
            "enable.idempotence": "true",
            "max.in.flight.requests.per.connection": "5",
            "message.max.bytes": "4194304",
            "queue.buffering.max.kbytes": "262144",
            "linger.ms": "100",
            "metadata.max.age.ms": "60000",
            "metadata.recovery.strategy": "rebootstrap",
            "metadata.recovery.rebootstrap.trigger.ms": "30000",
            "topic.metadata.refresh.interval.ms": "30000",
            "topic.metadata.refresh.fast.interval.ms": "250",
            "topic.metadata.refresh.sparse": "false",
            "reconnect.backoff.ms": "250",
            "reconnect.backoff.max.ms": "5000",
            "socket.keepalive.enable": "true",
        },
    }


def render_vector_config(source: str, pipeline: str, mode: str) -> str:
    config = yaml.safe_load(source)
    if mode == "shadow":
        for source_config in config.get("sources", {}).values():
            if source_config.get("type") in {"file", "kubernetes_logs"}:
                source_config["read_from"] = "end"
    config.setdefault("secret", {})["automq_auth"] = {
        "type": "directory",
        "path": "/var/run/secrets/automq",
    }
    config.setdefault("sources", {})["internal_metrics"] = {"type": "internal_metrics"}
    transforms = config.setdefault("transforms", {})
    sinks = config.setdefault("sinks", {})

    if pipeline == "vvg":
        direct_sink = copy.deepcopy(sinks.get("victorialogs"))
        if not direct_sink:
            raise SystemExit("VVG source must contain sinks.victorialogs")
        transforms["prepare_automq_event"] = {
            "type": "remap",
            "inputs": ["add_msg_field"],
            "source": BlockString(
                "._automq_event_timestamp = format_timestamp!(.timestamp, \"%+\")\n"
                "namespace = string(.kubernetes.pod_namespace) ?? \"unknown\"\n"
                "pod = string(.kubernetes.pod_name) ?? \"unknown\"\n"
                "container = string(.kubernetes.container_name) ?? \"unknown\"\n"
                "._automq_partition_key = namespace + \"/\" + pod + \"/\" + container\n"
            ),
        }
        transforms["route_automq_message_size"] = {
            "type": "route",
            "inputs": ["prepare_automq_event"],
            "route": {
                "normal": "length(encode_json(.)) <= 4000000",
                "oversized": "length(encode_json(.)) > 4000000 && length(encode_json(.)) <= 16000000",
                "extreme": "length(encode_json(.)) > 16000000",
            },
        }
        transforms["truncate_extreme_vvg_event"] = {
            "type": "remap",
            "inputs": ["route_automq_message_size.extreme"],
            "source": BlockString(
                "original_size = length(encode_json(.))\n"
                "original_message = string(.message) ?? \"\"\n"
                "message_chunks = chunks(original_message, 2000000)\n"
                "truncated_message = string(message_chunks[0]) ?? \"\"\n"
                "event_timestamp = .timestamp\n"
                "level = string(.level) ?? \"unknown\"\n"
                "namespace = string(.kubernetes.pod_namespace) ?? \"unknown\"\n"
                "pod = string(.kubernetes.pod_name) ?? \"unknown\"\n"
                "container = string(.kubernetes.container_name) ?? \"unknown\"\n"
                ". = {\n"
                "  \"timestamp\": event_timestamp,\n"
                "  \"message\": truncated_message,\n"
                "  \"_msg\": truncated_message,\n"
                "  \"level\": level,\n"
                "  \"kubernetes\": {\n"
                "    \"pod_namespace\": namespace,\n"
                "    \"pod_name\": pod,\n"
                "    \"container_name\": container\n"
                "  },\n"
                "  \"_automq_oversized\": true,\n"
                "  \"_automq_original_size_bytes\": original_size,\n"
                "  \"_automq_original_message_sha256\": sha2(original_message)\n"
                "}\n"
            ),
        }
        transforms["route_automq_producer_lane"] = {
            "type": "route",
            "inputs": ["route_automq_message_size.normal"],
            "route": {
                "lane_a": "mod((to_int(xxhash(string!(._automq_partition_key), \"XXH32\")) ?? 0), 2) == 0",
                "lane_b": "mod((to_int(xxhash(string!(._automq_partition_key), \"XXH32\")) ?? 0), 2) != 0",
            },
        }
        direct_sink["inputs"] = [
            "route_automq_message_size.oversized",
            "truncate_extreme_vvg_event",
        ]
        direct_sink["tenant_id"] = "${VLS_TENANT_ID}"
        direct_sink["acknowledgements"] = {"enabled": True}
        sinks.clear()
        sinks["automq_lane_a"] = kafka_sink(
            ["route_automq_producer_lane.lane_a"], 5368709120
        )
        sinks["automq_lane_b"] = kafka_sink(
            ["route_automq_producer_lane.lane_b"], 5368709120
        )
        sinks["victorialogs_oversized"] = direct_sink
        metrics_port = 9598
    else:
        if mode == "shadow":
            config["enrichment_tables"] = replace_string_values(
                config.get("enrichment_tables", {}),
                "/var/lib/vector/geoip/", "/var/lib/vector-geoip/geoip/",
            )
        clickhouse_sinks = {
            name: sink for name, sink in sinks.items() if sink.get("type") == "clickhouse"
        }
        if len(clickhouse_sinks) != 1:
            raise SystemExit(
                f"Gateway source must contain one ClickHouse sink, found {len(clickhouse_sinks)}"
            )
        clickhouse_sink = next(iter(clickhouse_sinks.values()))
        structured_inputs = clickhouse_sink.get("inputs", [])
        if not structured_inputs:
            raise SystemExit("Gateway ClickHouse sink must have at least one structured input")

        file_sources = [
            name for name, source in config.get("sources", {}).items()
            if source.get("type") == "file"
        ]
        if not file_sources:
            raise SystemExit("Gateway source must contain at least one file source")
        for source_name in file_sources:
            config["sources"][source_name]["max_line_bytes"] = 16777216
        for transform in transforms.values():
            transform["inputs"] = [
                "capture_automq_source_file" if item in file_sources else item
                for item in transform.get("inputs", [])
            ]
        transforms["capture_automq_source_file"] = {
            "type": "remap",
            "inputs": file_sources,
            "source": BlockString(
                "%automq_source_file = string(.file) ?? \"unknown\"\n"
            ),
        }
        transforms["prepare_automq_event"] = {
            "type": "remap",
            "inputs": structured_inputs,
            "source": BlockString(
                "._automq_event_timestamp = string!(.timestamp)\n"
                "._automq_partition_key = string(%automq_source_file) ?? \"unknown\"\n"
            ),
        }
        transforms["route_automq_gateway_size"] = {
            "type": "route",
            "inputs": ["prepare_automq_event"],
            "route": {
                "normal": "length(encode_json(.)) <= 4000000",
                "oversized": "length(encode_json(.)) > 4000000",
            },
        }
        preserved_sinks = {
            name: copy.deepcopy(sink)
            for name, sink in sinks.items()
            if sink.get("type") != "clickhouse"
        }
        fallback_sink = copy.deepcopy(clickhouse_sink)
        fallback_sink["inputs"] = ["route_automq_gateway_size.oversized"]
        fallback_sink["table"] = (
            "nginx_access_automq_shadow" if mode == "shadow"
            else clickhouse_sink.get("table", "nginx_access")
        )
        fallback_sink["auth"] = {
            "strategy": "basic",
            "user": "SECRET[clickhouse_auth.username]",
            "password": "SECRET[clickhouse_auth.password]",
        }
        fallback_sink["buffer"] = {
            "type": "memory", "max_events": 100, "when_full": "block"
        }
        config.setdefault("secret", {})["clickhouse_auth"] = {
            "type": "directory",
            "path": "/var/run/secrets/clickhouse",
        }
        sinks.clear()
        sinks["automq"] = kafka_sink(["route_automq_gateway_size.normal"], 2147483648)
        sinks["clickhouse_oversized_fallback"] = fallback_sink
        sinks.update(preserved_sinks)
        metrics_port = 9599

    sinks["metrics"] = {
        "type": "prometheus_exporter",
        "inputs": ["internal_metrics"],
        "address": f"0.0.0.0:{metrics_port}",
    }
    return yaml.dump(config, Dumper=ManifestDumper, sort_keys=False, allow_unicode=True)


def set_env(container: dict[str, Any], name: str, value: str) -> None:
    env = container.setdefault("env", [])
    env[:] = [item for item in env if item.get("name") != name]
    env.append({"name": name, "value": value})


def render_daemonset(
    source: dict[str, Any], pipeline: str, mode: str, configmap_name: str,
    source_configmap_name: str, vector_config_sha256: str,
    vector_image: str, bootstrap: str, shadow_state_suffix: str,
) -> dict[str, Any]:
    daemonset = clean_object(source)
    pod_spec = daemonset["spec"]["template"]["spec"]
    config_volume_name = next(
        (
            volume["name"]
            for volume in pod_spec.get("volumes", [])
            if volume.get("configMap", {}).get("name") == source_configmap_name
        ),
        None,
    )
    if not config_volume_name:
        raise SystemExit("Vector source must mount its ConfigMap as a volume")
    pod_spec["terminationGracePeriodSeconds"] = 120
    daemonset["spec"]["template"]["metadata"].setdefault("annotations", {})[
        "vvg.jinlingkeji.cn/vector-config-sha256"
    ] = vector_config_sha256
    containers = pod_spec["containers"]
    vector = next(container for container in containers if container.get("name") == "vector")
    vector["image"] = vector_image
    vector["imagePullPolicy"] = "IfNotPresent"

    if mode == "shadow":
        app = f"vector-automq-{pipeline}-shadow"
        daemonset["metadata"]["name"] = app
        daemonset["metadata"]["labels"] = {"app": app}
        daemonset["spec"]["selector"]["matchLabels"] = {"app": app}
        daemonset["spec"]["template"]["metadata"]["labels"] = {"app": app}
        daemonset["spec"]["template"]["metadata"].setdefault("annotations", {})[
            "vvg.jinlingkeji.cn/automq-mode"
        ] = "shadow"
    else:
        daemonset["spec"]["template"]["metadata"].setdefault("annotations", {})[
            "vvg.jinlingkeji.cn/automq-mode"
        ] = "production"

    set_env(vector, "AUTOMQ_BOOTSTRAP_SERVERS", bootstrap)
    set_env(vector, "AUTOMQ_TOPIC", "vvg.logs.v1" if pipeline == "vvg" else "gateway.access.v1")
    set_env(vector, "AUTOMQ_PRODUCER_USERNAME", f"{pipeline}-producer")
    set_env(vector, "AUTOMQ_METRICS_PORT", str(9598 if pipeline == "vvg" else 9599))
    set_env(
        vector,
        "AUTOMQ_STALL_BUFFER_THRESHOLD_BYTES",
        str(67108864 if pipeline == "vvg" else 1048576),
    )
    set_env(vector, "VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION", "true")
    if pipeline == "vvg":
        set_env(vector, "VLS_TENANT_ID", "99:99" if mode == "shadow" else "0:0")

    ports = vector.setdefault("ports", [])
    ports[:] = [port for port in ports if port.get("name") != "automq-metrics"]
    metrics_port = 9598 if pipeline == "vvg" else 9599
    ports.append({"name": "automq-metrics", "containerPort": metrics_port, "hostPort": metrics_port})

    vector["livenessProbe"] = {
        "exec": {
            "command": [
                "/bin/sh",
                "/opt/automq-health/producer-stall-check.sh",
            ]
        },
        "initialDelaySeconds": 60,
        "periodSeconds": 30,
        "timeoutSeconds": 10,
        "failureThreshold": 3,
        "successThreshold": 1,
    }

    mounts = vector.setdefault("volumeMounts", [])
    mounts[:] = [mount for mount in mounts if mount.get("name") not in {"automq-auth", "clickhouse-auth"}]
    mounts.append({"name": "automq-auth", "mountPath": "/var/run/secrets/automq", "readOnly": True})
    mounts.append({
        "name": config_volume_name,
        "mountPath": "/opt/automq-health/producer-stall-check.sh",
        "subPath": "producer-stall-check.sh",
        "readOnly": True,
    })
    if pipeline == "gateway":
        mounts.append({
            "name": "clickhouse-auth",
            "mountPath": "/var/run/secrets/clickhouse",
            "readOnly": True,
        })

    volumes = pod_spec.setdefault("volumes", [])
    volumes[:] = [volume for volume in volumes if volume.get("name") not in {"automq-auth", "clickhouse-auth"}]
    volumes.append({
        "name": "automq-auth",
        "secret": {"secretName": f"automq-{pipeline}-producer"},
    })
    if pipeline == "gateway":
        volumes.append({
            "name": "clickhouse-auth",
            "secret": {"secretName": "automq-gateway-clickhouse-fallback"},
        })
    for volume in volumes:
        if volume.get("name") == "config" or volume.get("configMap", {}).get("name") == source_configmap_name:
            volume["configMap"] = {"name": configmap_name}
        if volume.get("name") in {"data", "state", "vector-data"} and mode == "shadow":
            volume["hostPath"] = {
                "path": f"/var/lib/vector-automq-{pipeline}-shadow{shadow_state_suffix}",
                "type": "DirectoryOrCreate",
            }

    if pipeline == "gateway" and mode == "shadow":
        pod_spec.pop("initContainers", None)
        volumes[:] = [volume for volume in volumes if volume.get("name") != "geoip-data"]
        volumes.append({
            "name": "geoip-data",
            "hostPath": {"path": "/var/lib/vector-gateway", "type": "Directory"},
        })
        mounts[:] = [mount for mount in mounts if mount.get("name") != "geoip-data"]
        mounts.append({
            "name": "geoip-data",
            "mountPath": "/var/lib/vector-geoip",
            "readOnly": True,
        })

    return daemonset


def main() -> None:
    args = parse_args()
    documents = [doc for doc in yaml.safe_load_all(args.input.read_text(encoding="utf-8")) if doc]
    configmap = find_resource(documents, "ConfigMap", lambda item: "vector.yaml" in item.get("data", {}))
    daemonset = find_resource(
        documents,
        "DaemonSet",
        lambda item: any(c.get("name") == "vector" for c in item["spec"]["template"]["spec"]["containers"]),
    )

    source_configmap_name = configmap["metadata"]["name"]
    if args.mode == "shadow":
        configmap["metadata"]["name"] = f"vector-automq-{args.pipeline}-shadow-config"
    configmap_name = configmap["metadata"]["name"]
    vector_config = render_vector_config(
        configmap["data"]["vector.yaml"], args.pipeline, args.mode
    )
    configmap["data"]["vector.yaml"] = BlockString(vector_config)
    configmap["data"]["producer-stall-check.sh"] = BlockString(
        PRODUCER_STALL_CHECK_SCRIPT
    )
    vector_config_sha256 = hashlib.sha256(
        (vector_config + PRODUCER_STALL_CHECK_SCRIPT).encode("utf-8")
    ).hexdigest()
    daemonset = render_daemonset(
        daemonset, args.pipeline, args.mode, configmap_name, source_configmap_name,
        vector_config_sha256, args.vector_image, args.bootstrap,
        args.shadow_state_suffix,
    )

    output = yaml.dump_all(
        [configmap, daemonset], Dumper=ManifestDumper, sort_keys=False,
        allow_unicode=True, explicit_start=True,
    )
    args.output.write_text(output, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
