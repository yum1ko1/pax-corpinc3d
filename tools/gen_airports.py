"""Pax CorpInc3D: config/airports.json from OurAirports (public domain, https://ourairports.com/data/).

    python tools/gen_airports.py airports.csv runways.csv pax_corpinc3d/config/airports.json

Every large airport with scheduled flights and an IATA code (and medium ones with scheduled flights in countries
that have no large one): [lat, lon, IATA, name, city, the longest runway's heading (degrees true), its length (m),
elevation (m), 1 — a large airport]. The 3D jets (src/layers/planes3d.gd) take off from and land on these runways.
"""
import csv
import json
import sys


def main(ap_csv: str, rw_csv: str, out: str) -> None:
    rows = list(csv.DictReader(open(ap_csv, encoding="utf-8")))
    best_rw: dict = {}
    for r in csv.DictReader(open(rw_csv, encoding="utf-8")):
        if r["closed"] == "1":
            continue
        try:
            length = float(r["length_ft"] or 0)
        except ValueError:
            continue
        hd = r["le_heading_degT"]
        if not hd:
            try:
                hd = str((int("".join(ch for ch in r["le_ident"] if ch.isdigit()) or "0") * 10) % 360)
            except ValueError:
                hd = "0"
        ref = r["airport_ref"]
        if ref not in best_rw or length > best_rw[ref][0]:
            best_rw[ref] = (length, float(hd or 0))
    large_countries = {r["iso_country"] for r in rows if r["type"] == "large_airport" and r["scheduled_service"] == "yes"}
    out_rows = []
    for r in rows:
        if r["scheduled_service"] != "yes" or not r["iata_code"]:
            continue
        if r["type"] == "large_airport" or (r["type"] == "medium_airport" and r["iso_country"] not in large_countries):
            length, heading = best_rw.get(r["id"], (8000.0, 0.0))
            out_rows.append([round(float(r["latitude_deg"]), 4), round(float(r["longitude_deg"]), 4), r["iata_code"],
                r["name"], r["municipality"], round(heading, 1), round(length * 0.3048),
                round(float(r["elevation_ft"] or 0) * 0.3048), 1 if r["type"] == "large_airport" else 0])
    out_rows.sort(key=lambda a: a[2])
    data = {"_": "Аэропорты для 3D-самолётов Pax CorpInc3D (OurAirports, общественное достояние): [широта, долгота, ИАТА, "
                 "название, город, курс самой длинной ВПП (градусы), её длина (м), высота (м), 1 — крупный]. Крупные аэропорты с "
                 "регулярными рейсами; в странах без крупных — средние. Строит tools/gen_airports.py.",
            "airports": out_rows}
    json.dump(data, open(out, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    print(len(out_rows), "airports")


if __name__ == "__main__":
    main(*sys.argv[1:4])
