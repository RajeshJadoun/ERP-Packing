#!/usr/bin/env python3
"""Safe test-data cleanup mechanism for Packing ERP.

Cleans up test records created with the prefix 'TEST-E2E-' in reverse dependency order.
Only executes when explicitly authorized with --allow-cleanup and --env=staging.
"""

from __future__ import annotations

import argparse
import os
import sys
from urllib.parse import urlparse
import psycopg


def get_db_url() -> str:
    db_url = os.environ.get("DATABASE_URL")
    if db_url:
        return db_url
    env_file = os.path.join(os.path.dirname(__file__), "..", "backend", ".env")
    if os.path.exists(env_file):
        with open(env_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    if k.strip() == "DATABASE_URL":
                        return v.strip()
    raise RuntimeError("DATABASE_URL not found in environment or backend/.env")


def assert_expected_staging_database(db_url: str, parsed_url) -> None:
    expected_ref = os.environ.get("E2E_EXPECTED_SUPABASE_REF", "").strip()
    if not expected_ref:
        raise PermissionError(
            "E2E_EXPECTED_SUPABASE_REF must identify the exact staging project before any writes."
        )
    target_identity = f"{parsed_url.hostname or ''} {parsed_url.username or ''}".lower()
    if expected_ref.lower() not in target_identity:
        raise PermissionError(
            "Database target does not match E2E_EXPECTED_SUPABASE_REF; refusing cleanup."
        )


def cleanup_test_data(allow_cleanup: bool = False, env_name: str = "") -> dict[str, int]:
    if env_name.lower() != "staging":
        raise PermissionError(
            f"Cleanup blocked: E2E_ENV must be 'staging' (current: '{env_name}')."
        )
    if not allow_cleanup:
        raise PermissionError(
            "Cleanup blocked: E2E_ALLOW_CLEANUP must be true or --allow-cleanup specified."
        )

    db_url = get_db_url()
    parsed = urlparse(db_url)
    assert_expected_staging_database(db_url, parsed)
    print(f"[*] Connecting to verified staging database for cleanup: {parsed.hostname}:{parsed.port}{parsed.path}")

    counts: dict[str, int] = {}

    with psycopg.connect(db_url, autocommit=False) as conn:
        with conn.cursor() as cur:
            # 1. Check for transactional dependencies
            cur.execute("""
                SELECT count(*) FROM public.stock_transactions st
                JOIN public.materials m ON st.material_id = m.id
                WHERE m.material_code LIKE 'TEST-E2E-%';
            """)
            st_count = cur.fetchone()[0]
            if st_count > 0:
                raise RuntimeError(
                    f"Cleanup refused: {st_count} authoritative stock transactions reference TEST-E2E materials. "
                    "Do not delete ledger history; after acceptance, remove the disposable staging project instead."
                )

            # 2. Delete test BOM lines and BOMs
            cur.execute("""
                DELETE FROM public.bom_lines
                WHERE bom_id IN (
                    SELECT id FROM public.boms WHERE bom_code LIKE 'BOM-TEST-E2E-%'
                );
            """)
            counts["bom_lines"] = cur.rowcount

            cur.execute("""
                DELETE FROM public.bom_revision_events
                WHERE bom_id IN (
                    SELECT id FROM public.boms WHERE bom_code LIKE 'BOM-TEST-E2E-%'
                );
            """)
            counts["bom_revision_events"] = cur.rowcount

            cur.execute("DELETE FROM public.boms WHERE bom_code LIKE 'BOM-TEST-E2E-%';")
            counts["boms"] = cur.rowcount

            # 3. Delete test Workers
            cur.execute("DELETE FROM public.workers WHERE worker_code LIKE 'TEST-E2E-%';")
            counts["workers"] = cur.rowcount

            # 4. Delete test Locations
            cur.execute("DELETE FROM public.locations WHERE location_code LIKE 'TEST-E2E-%';")
            counts["locations"] = cur.rowcount

            # 5. Delete test Material Conversions
            cur.execute("""
                DELETE FROM public.material_conversions
                WHERE material_id IN (
                    SELECT id FROM public.materials WHERE material_code LIKE 'TEST-E2E-%'
                );
            """)
            counts["material_conversions"] = cur.rowcount

            # 6. Delete test Materials
            cur.execute("DELETE FROM public.materials WHERE material_code LIKE 'TEST-E2E-%';")
            counts["materials"] = cur.rowcount

            # 7. Delete test Products
            cur.execute("DELETE FROM public.products WHERE sku_code LIKE 'TEST-E2E-%';")
            counts["products"] = cur.rowcount

            # 8. Delete test Customer Parties
            cur.execute("DELETE FROM public.parties WHERE code LIKE 'TEST-E2E-%';")
            counts["parties"] = cur.rowcount

            # 9. Delete test Vendors
            cur.execute("DELETE FROM public.vendors WHERE vendor_code LIKE 'TEST-E2E-%';")
            counts["vendors"] = cur.rowcount

            # 10. Delete test Categories
            cur.execute("DELETE FROM public.material_categories WHERE code LIKE 'TEST-E2E-%';")
            counts["material_categories"] = cur.rowcount

            conn.commit()
            print("[+] Cleanup transaction committed successfully.")

    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description="Safely clean up TEST-E2E- records from test database.")
    parser.add_argument("--env", default=os.environ.get("E2E_ENV", ""), help="Target environment (must be 'staging')")
    parser.add_argument(
        "--allow-cleanup",
        action="store_true",
        default=os.environ.get("E2E_ALLOW_CLEANUP", "false").lower() in ("true", "1", "yes"),
        help="Explicit permission to clean up test database records",
    )
    args = parser.parse_args()

    try:
        counts = cleanup_test_data(allow_cleanup=args.allow_cleanup, env_name=args.env)
        print("\n=== Cleanup Summary ===")
        for k, v in counts.items():
            print(f"  {k} deleted: {v}")
    except Exception as exc:
        print(f"\n[!] Cleanup aborted: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
