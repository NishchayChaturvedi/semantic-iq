#!/usr/bin/env python3
"""
load_to_snowflake.py — loads all raw CSVs into Snowflake SEMANTIC_IQ.RAW.
Uses key-pair authentication (no password). Run generate_data.py first.

Strategy: PUT CSV to a session stage → COPY INTO with all-VARCHAR DDL.
The raw layer stores everything as text; dbt staging applies proper types.

Expected .env variables:
  SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PRIVATE_KEY_PATH,
  SNOWFLAKE_ROLE, SNOWFLAKE_WAREHOUSE, SNOWFLAKE_DATABASE, SNOWFLAKE_SCHEMA
  SNOWFLAKE_PRIVATE_KEY_PASSPHRASE  (optional — only if the .p8 is encrypted)
"""

import os
import sys
from pathlib import Path

import snowflake.connector
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, load_pem_private_key,
)
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

DATA_DIR = Path(__file__).parent

# csv filename → Snowflake table name (no raw_ prefix; lives in RAW schema)
TABLES = [
    ("raw_products.csv",            "PRODUCTS"),
    ("raw_accounts.csv",            "ACCOUNTS"),
    ("raw_account_ownership.csv",   "ACCOUNT_OWNERSHIP"),
    ("raw_api_keys.csv",            "API_KEYS"),
    ("raw_account_products.csv",    "ACCOUNT_PRODUCTS"),
    ("raw_fx_rates.csv",            "FX_RATES"),
    ("raw_subscriptions.csv",       "SUBSCRIPTIONS"),
    ("raw_usage_daily.csv",         "USAGE_DAILY"),
    ("raw_services_milestones.csv", "SERVICES_MILESTONES"),
]

CSV_FORMAT = """
    FILE_FORMAT = (
        TYPE                        = CSV
        FIELD_OPTIONALLY_ENCLOSED_BY = '"'
        SKIP_HEADER                 = 1
        NULL_IF                     = ('', 'None', 'nan', 'NaN', 'NULL')
        EMPTY_FIELD_AS_NULL         = TRUE
        DATE_FORMAT                 = AUTO
    )
    ON_ERROR = ABORT_STATEMENT
"""


def _load_private_key() -> bytes:
    path = os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"]
    passphrase_str = os.getenv("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE")
    password = passphrase_str.encode() if passphrase_str else None
    with open(path, "rb") as f:
        pk = load_pem_private_key(f.read(), password=password, backend=default_backend())
    return pk.private_bytes(
        encoding=Encoding.DER,
        format=PrivateFormat.PKCS8,
        encryption_algorithm=NoEncryption(),
    )


def get_connection() -> snowflake.connector.SnowflakeConnection:
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key=_load_private_key(),
        role=os.getenv("SNOWFLAKE_ROLE", "ACCOUNTADMIN"),
    )


def setup(conn: snowflake.connector.SnowflakeConnection) -> None:
    db        = os.getenv("SNOWFLAKE_DATABASE", "SEMANTIC_IQ")
    schema    = os.getenv("SNOWFLAKE_SCHEMA",   "RAW")
    warehouse = os.getenv("SNOWFLAKE_WAREHOUSE", "COMPUTE_WH")
    with conn.cursor() as cur:
        cur.execute(
            f"CREATE WAREHOUSE IF NOT EXISTS {warehouse} "
            f"WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE"
        )
        cur.execute(f"USE WAREHOUSE {warehouse}")
        cur.execute(f"CREATE DATABASE IF NOT EXISTS {db}")
        cur.execute(f"USE DATABASE {db}")
        cur.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
        cur.execute(f"USE SCHEMA {schema}")


def _csv_columns(csv_path: Path) -> list[str]:
    with open(csv_path) as f:
        return [c.strip().upper() for c in f.readline().split(",")]


def load_table(
    conn: snowflake.connector.SnowflakeConnection,
    csv_path: Path,
    table_name: str,
) -> int:
    cols = _csv_columns(csv_path)

    # All columns land as VARCHAR — dbt staging applies proper casts
    col_defs = ",\n        ".join(f"{c} VARCHAR" for c in cols)

    with conn.cursor() as cur:
        # Create (or replace) the table
        cur.execute(f"CREATE OR REPLACE TABLE {table_name} (\n        {col_defs}\n    )")

        # Upload CSV to the user stage (@~)
        cur.execute(
            f"PUT 'file://{csv_path.resolve()}' @~ "
            f"AUTO_COMPRESS=TRUE OVERWRITE=TRUE"
        )

        # Load from stage into table
        cur.execute(
            f"COPY INTO {table_name} "
            f"FROM @~/{csv_path.name}.gz "
            f"{CSV_FORMAT}"
        )

        cur.execute(f"SELECT COUNT(*) FROM {table_name}")
        return cur.fetchone()[0]


def main() -> None:
    db     = os.getenv("SNOWFLAKE_DATABASE", "SEMANTIC_IQ")
    schema = os.getenv("SNOWFLAKE_SCHEMA",   "RAW")

    missing = [t[0] for t in TABLES if not (DATA_DIR / t[0]).exists()]
    if missing:
        print("ERROR: missing CSV files — run generate_data.py first:")
        for f in missing:
            print(f"  {f}")
        sys.exit(1)

    print(f"Connecting to Snowflake ({db}.{schema}) …")
    conn = get_connection()
    setup(conn)
    print("Connected.\n")

    total_rows = 0
    for csv_name, table_name in TABLES:
        path = DATA_DIR / csv_name
        print(f"  Loading {table_name:<28}", end="", flush=True)
        rows = load_table(conn, path, table_name)
        print(f"  {rows:>7,} rows")
        total_rows += rows

    conn.close()
    print(f"\nDone — {total_rows:,} total rows in {db}.{schema}")


if __name__ == "__main__":
    main()
