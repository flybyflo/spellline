#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GTFS_DIR="$ROOT_DIR/gtfs_data"
OUTPUT_DIR="$ROOT_DIR/Spellline/preloaded_store"
OUT_DB="$OUTPUT_DIR/spellline.sqlite"

if [[ ! -d "$GTFS_DIR" ]]; then
  echo "Missing GTFS source directory: $GTFS_DIR" >&2
  exit 1
fi

for f in agency calendar calendar_dates levels pathways routes shapes stop_times stops trips; do
  if [[ ! -f "$GTFS_DIR/$f.txt" ]]; then
    echo "Missing GTFS file: $GTFS_DIR/$f.txt" >&2
    exit 1
  fi
done

mkdir -p "$OUTPUT_DIR"

python3 - "$GTFS_DIR" "$OUT_DB" <<'PY'
import csv
import os
import sqlite3
import sys
from pathlib import Path

gtfs = Path(sys.argv[1])
out_db = Path(sys.argv[2])
tmp_db = out_db.with_suffix(".sqlite.tmp")

mapping = [
    ("agency", "ZAGENCY"),
    ("calendar", "ZCALENDAR"),
    ("calendar_dates", "ZCALENDARDATE"),
    ("levels", "ZLEVEL"),
    ("pathways", "ZPATHWAY"),
    ("routes", "ZROUTE"),
    ("shapes", "ZSHAPEPOINT"),
    ("stop_times", "ZSTOPTIME"),
    ("stops", "ZSTOP"),
    ("trips", "ZTRIP"),
]

if tmp_db.exists():
    tmp_db.unlink()
if out_db.exists():
    out_db.unlink()

con = sqlite3.connect(tmp_db)
cur = con.cursor()
cur.execute("PRAGMA journal_mode=OFF")
cur.execute("PRAGMA synchronous=OFF")
cur.execute("PRAGMA temp_store=MEMORY")

cur.executescript(
    """
    CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
    CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR, Z_PLIST BLOB);
    CREATE TABLE Z_MODELCACHE (Z_CONTENT BLOB);
    CREATE TABLE ZAGENCY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAGENCY_EMAIL VARCHAR, ZAGENCY_FARE_URL VARCHAR, ZAGENCY_ID VARCHAR, ZAGENCY_LANG VARCHAR, ZAGENCY_NAME VARCHAR, ZAGENCY_PHONE VARCHAR, ZAGENCY_TIMEZONE VARCHAR, ZAGENCY_URL VARCHAR);
    CREATE TABLE ZCALENDAR (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZEND_DATE VARCHAR, ZFRIDAY VARCHAR, ZMONDAY VARCHAR, ZSATURDAY VARCHAR, ZSERVICE_ID VARCHAR, ZSTART_DATE VARCHAR, ZSUNDAY VARCHAR, ZTHURSDAY VARCHAR, ZTUESDAY VARCHAR, ZWEDNESDAY VARCHAR);
    CREATE TABLE ZCALENDARDATE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDATE VARCHAR, ZEXCEPTION_TYPE VARCHAR, ZSERVICE_ID VARCHAR);
    CREATE TABLE ZLEVEL (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLEVEL_ID VARCHAR, ZLEVEL_INDEX VARCHAR, ZLEVEL_NAME VARCHAR);
    CREATE TABLE ZPATHWAY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZFROM_STOP_ID VARCHAR, ZIS_BIDIRECTIONAL VARCHAR, ZLENGTH VARCHAR, ZMAX_SLOPE VARCHAR, ZMIN_WIDTH VARCHAR, ZPATHWAY_ID VARCHAR, ZPATHWAY_MODE VARCHAR, ZREVERSED_SIGNPOSTED_AS VARCHAR, ZSIGNPOSTED_AS VARCHAR, ZSTAIR_COUNT VARCHAR, ZTO_STOP_ID VARCHAR, ZTRAVERSAL_TIME VARCHAR);
    CREATE TABLE ZROUTE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAGENCY_ID VARCHAR, ZCONTINUOUS_DROP_OFF VARCHAR, ZCONTINUOUS_PICKUP VARCHAR, ZNETWORK_ID VARCHAR, ZROUTE_COLOR VARCHAR, ZROUTE_DESC VARCHAR, ZROUTE_ID VARCHAR, ZROUTE_LONG_NAME VARCHAR, ZROUTE_SHORT_NAME VARCHAR, ZROUTE_SORT_ORDER VARCHAR, ZROUTE_TEXT_COLOR VARCHAR, ZROUTE_TYPE VARCHAR, ZROUTE_URL VARCHAR);
    CREATE TABLE ZSHAPEPOINT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZSHAPE_DIST_TRAVELED VARCHAR, ZSHAPE_ID VARCHAR, ZSHAPE_PT_LAT VARCHAR, ZSHAPE_PT_LON VARCHAR, ZSHAPE_PT_SEQUENCE VARCHAR);
    CREATE TABLE ZSTOP (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLEVEL_ID VARCHAR, ZLOCATION_TYPE VARCHAR, ZPARENT_STATION VARCHAR, ZPLATFORM_CODE VARCHAR, ZSTOP_CODE VARCHAR, ZSTOP_DESC VARCHAR, ZSTOP_ID VARCHAR, ZSTOP_LAT VARCHAR, ZSTOP_LON VARCHAR, ZSTOP_NAME VARCHAR, ZSTOP_TIMEZONE VARCHAR, ZSTOP_URL VARCHAR, ZTTS_STOP_NAME VARCHAR, ZWHEELCHAIR_BOARDING VARCHAR, ZZONE_ID VARCHAR);
    CREATE TABLE ZSTOPTIME (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZARRIVAL_TIME VARCHAR, ZCONTINUOUS_DROP_OFF VARCHAR, ZCONTINUOUS_PICKUP VARCHAR, ZDEPARTURE_TIME VARCHAR, ZDROP_OFF_TYPE VARCHAR, ZPICKUP_TYPE VARCHAR, ZSHAPE_DIST_TRAVELED VARCHAR, ZSTOP_HEADSIGN VARCHAR, ZSTOP_ID VARCHAR, ZSTOP_SEQUENCE VARCHAR, ZTIMEPOINT VARCHAR, ZTRIP_ID VARCHAR);
    CREATE TABLE ZTRIP (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZBIKES_ALLOWED VARCHAR, ZBLOCK_ID VARCHAR, ZDIRECTION_ID VARCHAR, ZROUTE_ID VARCHAR, ZSERVICE_ID VARCHAR, ZSHAPE_ID VARCHAR, ZTRIP_HEADSIGN VARCHAR, ZTRIP_ID VARCHAR, ZTRIP_SHORT_NAME VARCHAR, ZWHEELCHAIR_ACCESSIBLE VARCHAR);
    CREATE TABLE ZIMPORTSTATE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDATASETVERSION VARCHAR, ZIDENTIFIER VARCHAR, ZIMPORTEDAT TIMESTAMP);
    """
)

entity_order = ["ZAGENCY","ZCALENDAR","ZCALENDARDATE","ZLEVEL","ZPATHWAY","ZROUTE","ZSHAPEPOINT","ZSTOP","ZSTOPTIME","ZTRIP","ZIMPORTSTATE"]
for idx, name in enumerate(entity_order, start=1):
    cur.execute("INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_SUPER, Z_MAX) VALUES (?, ?, NULL, 0)", (idx, name))

def coredata_col(header: str) -> str:
    return "Z" + header.strip().replace("-", "_").upper()

pk = 1
for file_name, table in mapping:
    path = gtfs / f"{file_name}.txt"
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        headers = reader.fieldnames or []
        cols = [coredata_col(h) for h in headers]
        placeholders = ",".join(["?"] * (3 + len(cols)))
        sql = f"INSERT INTO {table} (Z_PK,Z_ENT,Z_OPT,{','.join(cols)}) VALUES ({placeholders})"
        ent = entity_order.index(table) + 1
        batch = []
        count = 0
        for row in reader:
            values = [None if (row.get(h) or "").strip() == "" else row.get(h).strip() for h in headers]
            batch.append([pk, ent, 1, *values])
            pk += 1
            count += 1
            if len(batch) >= 10000:
                cur.executemany(sql, batch)
                batch.clear()
        if batch:
            cur.executemany(sql, batch)
        cur.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME=?", (count, table))
        con.commit()
        print(f"{table}: {count}")

cur.execute(
    "INSERT INTO ZIMPORTSTATE (Z_PK,Z_ENT,Z_OPT,ZDATASETVERSION,ZIDENTIFIER,ZIMPORTEDAT) VALUES (?,?,?,?,?,datetime('now'))",
    (pk, entity_order.index("ZIMPORTSTATE") + 1, 1, "preloaded-gtfs-v1", "default")
)
cur.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=1 WHERE Z_NAME='ZIMPORTSTATE'")
con.commit()
con.close()
tmp_db.replace(out_db)
print(f"Generated: {out_db}")
PY

rm -f "${OUT_DB}-wal" "${OUT_DB}-shm"
echo "Done. Store files are in: $OUTPUT_DIR"
