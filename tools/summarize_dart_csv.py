#!/usr/bin/env python3
"""Summarize Aether Grid MQTT CSV logs using only the Python standard library.

Input files use the MqttService header:
run_label,broker,qos,seq,t_send_us,rtt_us,esp_proc_us

Pass one or more CSV files or directories. The input filename is retained as a
condition label, so use descriptive names such as qos0_vision_on.csv.
"""

from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import median


def percentile(values: list[float], quantile: float) -> float | None:
    """Linearly interpolated percentile; returns None for an empty list."""
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    fraction = position - low
    return ordered[low] + (ordered[high] - ordered[low]) * fraction


def csv_paths(inputs: list[Path], output: Path) -> list[Path]:
    found: set[Path] = set()
    for item in inputs:
        if item.is_dir():
            found.update(path.resolve() for path in item.glob("*.csv"))
        elif item.is_file() and item.suffix.lower() == ".csv":
            found.add(item.resolve())
    found.discard(output.resolve())
    return sorted(found)


def summarize(paths: list[Path]) -> list[dict[str, object]]:
    groups: dict[tuple[str, str, str, str], dict[str, list[float] | int]] = (
        defaultdict(lambda: {"rows": 0, "rtt_ms": [], "esp_proc_us": [], "send_us": []})
    )

    for path in paths:
        with path.open("r", newline="", encoding="utf-8-sig") as source:
            reader = csv.DictReader(source)
            required = {"run_label", "broker", "qos", "seq", "t_send_us", "rtt_us", "esp_proc_us"}
            missing = required - set(reader.fieldnames or [])
            if missing:
                print(f"Skipping {path}: missing columns {', '.join(sorted(missing))}")
                continue

            condition = path.stem
            for row in reader:
                key = (
                    condition,
                    row.get("run_label", "").strip(),
                    row.get("broker", "").strip(),
                    row.get("qos", "").strip(),
                )
                group = groups[key]
                group["rows"] = int(group["rows"]) + 1
                try:
                    group["send_us"].append(float(row["t_send_us"]))  # type: ignore[union-attr]
                except (TypeError, ValueError):
                    pass
                try:
                    group["rtt_ms"].append(float(row["rtt_us"]) / 1000)  # type: ignore[union-attr]
                except (TypeError, ValueError):
                    pass  # An empty RTT cell is a logged send with no echo.
                try:
                    group["esp_proc_us"].append(float(row["esp_proc_us"]))  # type: ignore[union-attr]
                except (TypeError, ValueError):
                    pass

    summaries: list[dict[str, object]] = []
    for (condition, run_label, broker, qos), group in sorted(groups.items()):
        rtts = group["rtt_ms"]
        processing = group["esp_proc_us"]
        sends = group["send_us"]
        sent_rows = int(group["rows"])
        received = len(rtts)  # type: ignore[arg-type]
        elapsed_s = (
            (max(sends) - min(sends)) / 1_000_000  # type: ignore[arg-type]
            if len(sends) > 1  # type: ignore[arg-type]
            else 0.0
        )
        summaries.append(
            {
                "condition_file": condition,
                "run_label": run_label,
                "broker": broker,
                "qos": qos,
                "logged_sends": sent_rows,
                "echoes": received,
                "no_echo_rows": sent_rows - received,
                "echo_rate_pct": 100 * received / sent_rows if sent_rows else 0.0,
                "duration_s": elapsed_s,
                "median_rtt_ms": median(rtts) if rtts else "",  # type: ignore[arg-type]
                "p95_rtt_ms": percentile(rtts, 0.95) if rtts else "",  # type: ignore[arg-type]
                "p99_rtt_ms": percentile(rtts, 0.99) if rtts else "",  # type: ignore[arg-type]
                "max_rtt_ms": max(rtts) if rtts else "",  # type: ignore[arg-type]
                "median_esp_proc_us": median(processing) if processing else "",  # type: ignore[arg-type]
                "p95_esp_proc_us": percentile(processing, 0.95) if processing else "",  # type: ignore[arg-type]
            }
        )
    return summaries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="CSV files and/or directories")
    parser.add_argument("--output", type=Path, default=Path("dart_summary.csv"))
    args = parser.parse_args()

    paths = csv_paths(args.inputs, args.output)
    if not paths:
        raise SystemExit("No input CSV files found.")
    rows = summarize(paths)
    if not rows:
        raise SystemExit("No compatible MQTT CSV rows found.")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as target:
        writer = csv.DictWriter(target, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"Summarized {len(paths)} input file(s) into {args.output}")


if __name__ == "__main__":
    main()
