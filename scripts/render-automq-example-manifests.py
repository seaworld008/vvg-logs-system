#!/usr/bin/env python3
"""Render or verify the repository's production AutoMQ producer manifests."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
VECTOR_IMAGE = (
    "registry.example.com/observability/timberio/vector:0.58.0-alpine@"
    "sha256:732a0051fffd0a402c8a1030f3afc4fa1282cb8b7c992e328e67f0a7cf2e0e45"
)
BOOTSTRAP_SERVERS = "automq.example.internal:9092"
MANIFESTS = (
    (
        "vvg",
        Path("k8s-deployment/vector/vvg/direct-containerd.yaml"),
        Path("k8s-deployment/vector/vvg/automq-containerd-production.yaml"),
    ),
    (
        "gateway",
        Path("k8s-deployment/vector/gateway/direct-containerd.yaml"),
        Path("k8s-deployment/vector/gateway/automq-containerd-production.yaml"),
    ),
)


def resources(path: Path) -> list[dict]:
    return [
        document
        for document in yaml.safe_load_all(path.read_text(encoding="utf-8"))
        if document
    ]


def normalized_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


def one_resource(documents: list[dict], kind: str) -> dict:
    matches = [document for document in documents if document.get("kind") == kind]
    if len(matches) != 1:
        raise SystemExit(f"Expected one {kind}, found {len(matches)}")
    return matches[0]


def validate_pair(pipeline: str, source: Path, rendered: Path) -> None:
    source_documents = resources(REPO_ROOT / source)
    rendered_documents = resources(rendered)
    source_configmap = one_resource(source_documents, "ConfigMap")
    rendered_configmap = one_resource(rendered_documents, "ConfigMap")
    source_daemonset = one_resource(source_documents, "DaemonSet")
    rendered_daemonset = one_resource(rendered_documents, "DaemonSet")

    if source_configmap["metadata"]["name"] != rendered_configmap["metadata"]["name"]:
        raise SystemExit(f"{pipeline} ConfigMap identity changed")
    if source_daemonset["metadata"]["name"] != rendered_daemonset["metadata"]["name"]:
        raise SystemExit(f"{pipeline} DaemonSet identity changed")

    source_supporting = {
        (document.get("kind"), document.get("metadata", {}).get("name"))
        for document in source_documents
        if document.get("kind") not in {"ConfigMap", "DaemonSet"}
    }
    rendered_supporting = {
        (document.get("kind"), document.get("metadata", {}).get("name"))
        for document in rendered_documents
        if document.get("kind") not in {"ConfigMap", "DaemonSet"}
    }
    if source_supporting != rendered_supporting:
        raise SystemExit(f"{pipeline} supporting Kubernetes resources changed")

    config = yaml.safe_load(rendered_configmap["data"]["vector.yaml"])
    sinks = config["sinks"]
    if pipeline == "vvg":
        required = {"ServiceAccount", "ClusterRole", "ClusterRoleBinding"}
        if not required.issubset({document.get("kind") for document in rendered_documents}):
            raise SystemExit("VVG AutoMQ manifest is missing RBAC resources")
        if "victorialogs" in sinks or "victorialogs_oversized" not in sinks:
            raise SystemExit("VVG AutoMQ manifest has an invalid sink boundary")
        kafka_sinks = [sink for sink in sinks.values() if sink.get("type") == "kafka"]
        if len(kafka_sinks) != 2:
            raise SystemExit("VVG AutoMQ manifest must contain two Kafka lanes")
    else:
        if "clickhouse" in sinks or "clickhouse_oversized_fallback" not in sinks:
            raise SystemExit("Gateway AutoMQ manifest has an invalid sink boundary")
        kafka_sinks = [sink for sink in sinks.values() if sink.get("type") == "kafka"]
        if len(kafka_sinks) != 1:
            raise SystemExit("Gateway AutoMQ manifest must contain one Kafka sink")

    if not all(sink.get("compression") == "zstd" for sink in kafka_sinks):
        raise SystemExit(f"{pipeline} Kafka sinks must use Zstd")
    image = rendered_daemonset["spec"]["template"]["spec"]["containers"][0]["image"]
    if image != VECTOR_IMAGE:
        raise SystemExit(f"{pipeline} Vector image is not the pinned repository image")


def render(pipeline: str, source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "scripts/render-automq-vector-manifest.py"),
            "--pipeline",
            pipeline,
            "--mode",
            "production",
            "--input",
            str(REPO_ROOT / source),
            "--output",
            str(output),
            "--vector-image",
            VECTOR_IMAGE,
            "--bootstrap",
            BOOTSTRAP_SERVERS,
        ],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when committed manifests differ from freshly rendered output",
    )
    args = parser.parse_args()

    if not args.check:
        for pipeline, source, destination in MANIFESTS:
            output = REPO_ROOT / destination
            render(pipeline, source, output)
            validate_pair(pipeline, source, output)
            print(f"Rendered {destination.as_posix()}")
        return

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="automq-example-manifests-") as temp_dir:
        temp_root = Path(temp_dir)
        for pipeline, source, destination in MANIFESTS:
            candidate = temp_root / destination.name
            render(pipeline, source, candidate)
            validate_pair(pipeline, source, candidate)
            committed = REPO_ROOT / destination
            if not committed.exists() or normalized_text(committed) != normalized_text(candidate):
                failures.append(destination.as_posix())

    if failures:
        joined = ", ".join(failures)
        raise SystemExit(
            "Committed AutoMQ manifests are stale: "
            f"{joined}. Run scripts/render-automq-example-manifests.py."
        )
    print("Committed AutoMQ production manifests are freshly rendered")


if __name__ == "__main__":
    main()
