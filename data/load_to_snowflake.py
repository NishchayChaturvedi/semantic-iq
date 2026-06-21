#!/usr/bin/env python3
"""
load_to_snowflake.py — loads all raw CSVs into Snowflake SEMANTIC_IQ.RAW.
Uses key-pair authentication (no password). Run generate_data.py first.

Expected .env variables:
  SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PRIVATE_KEY_PATH,
  SNOWFLAKE_ROLE, SNOWFLAKE_WAREHOUSE, SNOWFLAKE_DATABASE, SNOWFLAKE_SCHEMA
  SNOWFLAKE_PRIVATE_KEY_PASSPHRASE  (optional — only if the .p8 is encrypted)
"""

import os
import sys
from pathlib import Path

import pandas as pd
import snowflake.connector
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, load_pem_private_key,
)
from dotenv import load_dotenv
from snowflake.connector.pandas_tools import write_pandas

load_dotenv()

DATA_DIR = Path(__file__).parent

# csv filename → Snowflake table name (load order respects no FK constraints in RAW)
TABLES = [
    ("raw_products.csv",            "RAW_PRODUCTS"),
    ("raw_accounts.csv",            "RAW_ACCOUNTS"),
    ("raw_account_ownership.csv",   "RAW_ACCOUNT_OWNERSHIP"),
    ("raw_api_keys.csv",            "RAW_API_KEYS"),
    ("raw_account_products.csv",    "RAW_ACCOUNT_PRODUCTS"),
    ("raw_fx_rates.csv",            "RAW_FX_RATES"),
    ("raw_subscriptions.csv",       "RAW_SUBSCRIPTIONS"),
    ("raw_usage_daily.csv",         "RAW_USAGE_DAILY"),
    ("raw_services_milestones.csv", "RAW_SERVICES_MILESTONES"),
]


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
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "COMPUTE_WH"),
        database=os.getenv("SNOWFLAKE_DATABASE", "SEMANTIC_IQ"),
        schema=os.getenv("SNOWFLAKE_SCHEMA", "RAW"),
    )


def ensure_db_and_schema(conn: snowflake.connector.SnowflakeConnection) -> None:
    db        = os.getenv("SNOWFLAKE_DATABASE", "SEMANTIC_IQ")
    schema    = os.getenv("SNOWFLAKE_SCHEMA",   "RAW")
    warehouse = os.getenv("SNOWFLAKE_WAREHOUSE", "COMPUTE_WH")
    with conn.cursor() as cur:
        cur.execute(
            f'CREATE WAREHOUSE IF NOT EXISTS "{warehouse}" '
            f'WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE'
        )
        cur.execute(f'USE WAREHOUSE "{warehouse}"')
        cur.execute(f'CREATE DATABASE IF NOT EXISTS "{db}"')
        cur.execute(f'USE DATABASE "{db}"')
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{schema}"')
        cur.execute(f'USE SCHEMA "{schema}"')


def load_table(
    conn: snowflake.connector.SnowflakeConnection,
    csv_path: Path,
    table_name: str,
) -> int:
    df = pd.read_csv(csv_path, low_memory=False)
    # Snowflake conventionally uppercases unquoted identifiers
    df.columns = [c.upper() for c in df.columns]

    success, _chunks, nrows, _ = write_pandas(
        conn, df, table_name,
        auto_create_table=True,
        overwrite=True,          # drop + recreate for idempotent re-runs
        quote_identifiers=False,
    )
    if not success:
        raise RuntimeError(f"write_pandas reported failure for {table_name}")
    return nrows


def main() -> None:
    db     = os.getenv("SNOWFLAKE_DATABASE", "SEMANTIC_IQ")
    schema = os.getenv("SNOWFLAKE_SCHEMA",   "RAW")

    # Pre-flight: confirm all CSVs exist before opening connection
    missing = [t[0] for t in TABLES if not (DATA_DIR / t[0]).exists()]
    if missing:
        print("ERROR: missing CSV files — run generate_data.py first:")
        for f in missing:
            print(f"  {f}")
        sys.exit(1)

    print(f"Connecting to Snowflake ({db}.{schema}) …")
    conn = get_connection()
    ensure_db_and_schema(conn)
    print("Connected.\n")

    total_rows = 0
    for csv_name, table_name in TABLES:
        path = DATA_DIR / csv_name
        print(f"  Loading {table_name:<30}", end="", flush=True)
        rows = load_table(conn, path, table_name)
        print(f"  {rows:>7,} rows")
        total_rows += rows

    conn.close()
    print(f"\nDone — {total_rows:,} total rows in {db}.{schema}")


if __name__ == "__main__":
    main()
