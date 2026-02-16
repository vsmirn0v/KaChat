#!/usr/bin/env python3
"""
Build a compact GeoIP JSON for KaChat from DB-IP Lite CSV datasets.

Downloads DB-IP Lite City + ASN CSVs from sapics/ip-location-db,
aggregates to /16 blocks, merges ASN data, and outputs compact JSON.

DB-IP Lite is licensed under CC BY 4.0 (https://db-ip.com).

Usage:
  # Auto-download and build (requires internet)
  python3 scripts/build_geoip_lite.py --output KaChat/Resources/geoip-lite.json

  # Build from local CSVs
  python3 scripts/build_geoip_lite.py \
    --city-csv /path/to/dbip-city-ipv4.csv \
    --asn-csv /path/to/dbip-asn-ipv4.csv \
    --output KaChat/Resources/geoip-lite.json
"""

from __future__ import annotations

import argparse
import csv
import gzip
import ipaddress
import json
import os
import sys
import tempfile
import urllib.request
from collections import defaultdict
from pathlib import Path
from typing import List, Optional, Tuple

CITY_CSV_URL = "https://unpkg.com/@ip-location-db/dbip-city/dbip-city-ipv4.csv.gz"
ASN_CSV_URL = "https://raw.githubusercontent.com/sapics/ip-location-db/refs/heads/main/dbip-asn/dbip-asn-ipv4.csv"


def ip_to_int(ip_str: str) -> int:
    return int(ipaddress.ip_address(ip_str))


def is_private_prefix(cidr: str) -> bool:
    try:
        net = ipaddress.ip_network(cidr, strict=False)
        return net.is_private or net.is_reserved or net.is_loopback or net.is_link_local
    except Exception:
        return True


def download_file(url: str, dest: Path, decompress_gz: bool = False) -> None:
    print(f"  Downloading {url}...", flush=True)
    tmp_path = dest.with_suffix(dest.suffix + ".tmp")
    urllib.request.urlretrieve(url, tmp_path)
    if decompress_gz:
        print(f"  Decompressing...", flush=True)
        with gzip.open(tmp_path, "rb") as gz_in:
            dest.write_bytes(gz_in.read())
        tmp_path.unlink()
    else:
        tmp_path.rename(dest)


def load_asn_ranges(asn_csv: Path) -> List[Tuple[int, int, str]]:
    """Load ASN ranges sorted by start IP for binary search."""
    ranges = []
    with asn_csv.open("r", encoding="utf-8") as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) < 3:
                continue
            try:
                s = ip_to_int(row[0])
                e = ip_to_int(row[1])
                ranges.append((s, e, f"AS{row[2]}"))
            except Exception:
                continue
    ranges.sort(key=lambda x: x[0])
    return ranges


def find_asn(ip_int: int, asn_ranges: List[Tuple[int, int, str]]) -> Optional[str]:
    lo, hi = 0, len(asn_ranges) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        s, e, asn = asn_ranges[mid]
        if ip_int < s:
            hi = mid - 1
        elif ip_int > e:
            lo = mid + 1
        else:
            return asn
    return None


def build_database(city_csv: Path, asn_csv: Path, output: Path) -> None:
    print("Loading ASN data...", flush=True)
    asn_ranges = load_asn_ranges(asn_csv)
    print(f"  {len(asn_ranges)} ASN ranges", flush=True)

    print("Loading city data and aggregating to /16 blocks...", flush=True)
    # For each /16 prefix, collect (lat, lon, country, weight) entries
    prefix16_data: dict[int, list] = defaultdict(list)

    count = 0
    with city_csv.open("r", encoding="utf-8") as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) < 9:
                continue
            start_ip_str, end_ip_str = row[0], row[1]
            country = row[2].strip() if row[2] else ""
            lat_str, lon_str = row[7], row[8]

            if not lat_str or not lon_str:
                continue
            try:
                lat = float(lat_str)
                lon = float(lon_str)
                start_int = ip_to_int(start_ip_str)
                end_int = ip_to_int(end_ip_str)
            except Exception:
                continue

            weight = end_int - start_int + 1
            start_p16 = start_int >> 16
            end_p16 = end_int >> 16

            # Limit span to avoid degenerate ranges
            for p16 in range(start_p16, min(end_p16 + 1, start_p16 + 16)):
                prefix16_data[p16].append((lat, lon, country, weight))

            count += 1
            if count % 500000 == 0:
                print(f"  {count} rows...", flush=True)

    print(f"  {count} city rows -> {len(prefix16_data)} /16 prefixes", flush=True)

    print("Building output...", flush=True)
    entries = []

    for p16 in sorted(prefix16_data.keys()):
        data = prefix16_data[p16]
        total_weight = sum(d[3] for d in data)
        if total_weight == 0:
            continue

        avg_lat = sum(d[0] * d[3] for d in data) / total_weight
        avg_lon = sum(d[1] * d[3] for d in data) / total_weight

        # Most common country by weight
        country_weight: dict[str, int] = defaultdict(int)
        for d in data:
            if d[2]:
                country_weight[d[2]] += d[3]
        country = max(country_weight, key=country_weight.get) if country_weight else None

        base_ip = p16 << 16
        cidr = f"{(base_ip >> 24) & 0xFF}.{(base_ip >> 16) & 0xFF}.0.0/16"

        if is_private_prefix(cidr):
            continue

        asn = find_asn(base_ip, asn_ranges)

        entry: dict = {
            "cidr": cidr,
            "latitude": round(avg_lat, 2),
            "longitude": round(avg_lon, 2),
        }
        if country:
            entry["country_code"] = country
        if asn:
            entry["asn"] = asn

        entries.append(entry)

    output.parent.mkdir(parents=True, exist_ok=True)
    json_str = json.dumps(entries, separators=(",", ":"), ensure_ascii=True)
    output.write_text(json_str, encoding="utf-8")

    size_kb = len(json_str) / 1024
    with_asn = sum(1 for e in entries if "asn" in e)
    print(f"\nWrote {len(entries)} /16 entries to {output} ({size_kb:.0f} KB)")
    print(f"  With ASN: {with_asn} ({100 * with_asn / len(entries):.0f}%)")
    print(f"  With country: {sum(1 for e in entries if 'country_code' in e)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build local GeoIP JSON for KaChat from DB-IP Lite data."
    )
    parser.add_argument(
        "--city-csv", type=Path, default=None,
        help="Path to dbip-city-ipv4.csv (downloaded automatically if omitted)",
    )
    parser.add_argument(
        "--asn-csv", type=Path, default=None,
        help="Path to dbip-asn-ipv4.csv (downloaded automatically if omitted)",
    )
    parser.add_argument(
        "--output", type=Path, required=True,
        help="Output JSON path",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    tmpdir = Path(tempfile.mkdtemp(prefix="geoip-build-"))

    city_csv = args.city_csv
    asn_csv = args.asn_csv

    if city_csv is None:
        city_csv = tmpdir / "dbip-city-ipv4.csv"
        download_file(CITY_CSV_URL, city_csv, decompress_gz=True)

    if asn_csv is None:
        asn_csv = tmpdir / "dbip-asn-ipv4.csv"
        download_file(ASN_CSV_URL, asn_csv)

    build_database(city_csv, asn_csv, args.output)


if __name__ == "__main__":
    main()
