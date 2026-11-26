#!/usr/bin/env python3
"""Verify the fictional retrieval example without using VeraData."""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    example = Path(__file__).resolve().parents[1] / "Sources/VeraDataApp/Resources/demo.json"
    parser.add_argument("vault", nargs="?", type=Path, default=example)
    args = parser.parse_args()

    vault = json.loads(args.vault.read_text(encoding="utf-8"))
    assert vault["version"] == 1
    profile = next(profile for profile in vault["profiles"] if profile["id"] == "demo")
    records = {record["id"]: record for record in profile["records"]}
    contact = records["morgan-reed"]
    assert contact["fields"][contact["aliases"][";ph"]] == "+1 (202) 555-0142"
    roles = [record for record in records.values() if record["label"] == "Juniper Signal Works"]
    assert len(roles) == 2
    years = {role["fields"]["title"]: role["fields"]["startDate"].split("-")[0] for role in roles}
    assert years == {"Operations Lead": "2024", "Operations Coordinator": "2022"}
    if "latitude" in records["cedar-current"]["fields"]:
        address = records["cedar-current"]["fields"]
        assert (address["latitude"], address["longitude"]) == ("45.000000", "-123.000000")
    fields = contact["fields"]
    projection = {key: fields[key] for key in ("Reference code", "givenName")}
    assert projection == {"Reference code": "000184", "givenName": "Morgan"}
    print("Fictional phone, employment years, and selective JSON projection verified.")


if __name__ == "__main__":
    main()
