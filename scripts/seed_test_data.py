#!/usr/bin/env python3
"""Idempotent Test Data Seeder for Packing ERP.

Creates prerequisite master data with the prefix 'TEST-E2E-'.
Requires explicit environment guard flags:
  E2E_ENV=staging
  E2E_ALLOW_MUTATIONS=true
or CLI flags --env=staging --allow-mutations.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
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


def seed_data(allow_mutations: bool = False, env_name: str = "") -> dict[str, str]:
    if env_name.lower() != "staging":
        raise PermissionError(
            f"Seeder blocked: E2E_ENV must be set to 'staging' (current: '{env_name}'). "
            "Never run test seeders against unverified environments."
        )
    if not allow_mutations:
        raise PermissionError(
            "Seeder blocked: E2E_ALLOW_MUTATIONS must be true. "
            "Explicit write authorization is required before test data creation."
        )

    db_url = get_db_url()
    parsed = urlparse(db_url)
    print(f"[*] Connecting to test database: {parsed.hostname}:{parsed.port}{parsed.path}")

    created: dict[str, str] = {}

    with psycopg.connect(db_url, autocommit=False) as conn:
        with conn.cursor() as cur:
            # 1. Fetch Admin Profile ID for created_by references
            cur.execute(
                "SELECT id FROM public.profiles WHERE role = 'ADMIN' AND is_active = true ORDER BY created_at LIMIT 1;"
            )
            row = cur.fetchone()
            if not row:
                raise RuntimeError("No active ADMIN profile found in public.profiles to attribute created records.")
            admin_id = str(row[0])
            print(f"[+] Using Admin actor ID: {admin_id}")

            # 2. Fetch standard Unit IDs
            cur.execute("SELECT id, code FROM public.units WHERE code IN ('PCS', 'ROLL', 'BUNDLE', 'BOX', 'KG');")
            units_map = {r[1]: str(r[0]) for r in cur.fetchall()}
            for required_unit in ["PCS", "ROLL", "BUNDLE"]:
                if required_unit not in units_map:
                    raise RuntimeError(f"Standard unit {required_unit} missing from public.units.")
            pcs_unit_id = units_map["PCS"]
            roll_unit_id = units_map["ROLL"]
            bundle_unit_id = units_map["BUNDLE"]
            print(f"[+] Found standard units: PCS={pcs_unit_id[:8]}, ROLL={roll_unit_id[:8]}, BUNDLE={bundle_unit_id[:8]}")

            # 3. Category: TEST-E2E-CAT-CORR
            cat_code = "TEST-E2E-CAT-CORR"
            cur.execute(
                """
                INSERT INTO public.material_categories (code, name, description, is_active)
                VALUES (%s, %s, %s, true)
                ON CONFLICT (code) DO UPDATE
                SET name = EXCLUDED.name, description = EXCLUDED.description, is_active = true
                RETURNING id;
                """,
                (cat_code, "TEST-E2E Corrugated Shippers", "Master corrugated packing boxes for E2E suite"),
            )
            cat_id = str(cur.fetchone()[0])
            created["category_id"] = cat_id
            print(f"[+] Seeded category: {cat_code} ({cat_id})")

            # 4. Customer Party: TEST-E2E-PTY-01
            pty_code = "TEST-E2E-PTY-01"
            pty_contact = json.dumps({"email": "logistics@test-client.local", "phone": "+919876543210"})
            cur.execute(
                """
                INSERT INTO public.parties (code, name, contact_info, is_active)
                VALUES (%s, %s, %s::jsonb, true)
                ON CONFLICT (code) DO UPDATE
                SET name = EXCLUDED.name, contact_info = EXCLUDED.contact_info, is_active = true
                RETURNING id;
                """,
                (pty_code, "TEST-E2E Apex Retail Logistics", pty_contact),
            )
            pty_id = str(cur.fetchone()[0])
            created["party_id"] = pty_id
            print(f"[+] Seeded party: {pty_code} ({pty_id})")

            # 5. Product: TEST-E2E-SKU-100
            sku_code = "TEST-E2E-SKU-100"
            cur.execute(
                """
                INSERT INTO public.products (sku_code, name, description, default_party_id, is_active)
                VALUES (%s, %s, %s, %s, true)
                ON CONFLICT (sku_code) DO UPDATE
                SET name = EXCLUDED.name, description = EXCLUDED.description, default_party_id = EXCLUDED.default_party_id, is_active = true
                RETURNING id;
                """,
                (sku_code, "TEST-E2E Smart Speaker Kit", "Retail packaged electronic speaker with protective carton", pty_id),
            )
            prod_id = str(cur.fetchone()[0])
            created["product_id"] = prod_id
            print(f"[+] Seeded product: {sku_code} ({prod_id})")

            # 6. Materials: TEST-E2E-MAT-BOX and TEST-E2E-MAT-TAPE
            mat_box_code = "TEST-E2E-MAT-BOX"
            box_specs = json.dumps({"ply": 3, "burstStrength": "14 kg/cm2", "dimsMm": "300x200x150"})
            cur.execute(
                """
                INSERT INTO public.materials (material_code, name, category_id, canonical_unit_id, specifications, is_active)
                VALUES (%s, %s, %s, %s, %s::jsonb, true)
                ON CONFLICT (material_code) DO UPDATE
                SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, specifications = EXCLUDED.specifications, is_active = true
                RETURNING id;
                """,
                (mat_box_code, "TEST-E2E 3-Ply Folding Carton", cat_id, pcs_unit_id, box_specs),
            )
            mat_box_id = str(cur.fetchone()[0])
            created["material_box_id"] = mat_box_id
            print(f"[+] Seeded material: {mat_box_code} ({mat_box_id})")

            mat_tape_code = "TEST-E2E-MAT-TAPE"
            tape_specs = json.dumps({"widthMm": 48, "lengthMeters": 50, "color": "Brown"})
            cur.execute(
                """
                INSERT INTO public.materials (material_code, name, category_id, canonical_unit_id, specifications, is_active)
                VALUES (%s, %s, %s, %s, %s::jsonb, true)
                ON CONFLICT (material_code) DO UPDATE
                SET name = EXCLUDED.name, category_id = EXCLUDED.category_id, specifications = EXCLUDED.specifications, is_active = true
                RETURNING id;
                """,
                (mat_tape_code, "TEST-E2E BOPP Packing Tape 50m", cat_id, roll_unit_id, tape_specs),
            )
            mat_tape_id = str(cur.fetchone()[0])
            created["material_tape_id"] = mat_tape_id
            print(f"[+] Seeded material: {mat_tape_code} ({mat_tape_id})")

            # 7. Material Conversion: 1 BUNDLE = 25 PCS for TEST-E2E-MAT-BOX
            cur.execute(
                """
                SELECT id FROM public.material_conversions
                WHERE material_id = %s AND from_unit_id = %s AND to_unit_id = %s AND effective_to IS NULL;
                """,
                (mat_box_id, bundle_unit_id, pcs_unit_id),
            )
            conv_row = cur.fetchone()
            if not conv_row:
                cur.execute(
                    """
                    INSERT INTO public.material_conversions (
                        material_id, from_unit_id, to_unit_id, conversion_factor, is_exact,
                        effective_from, notes, created_by
                    ) VALUES (%s, %s, %s, 25.0, true, clock_timestamp(), %s, %s)
                    RETURNING id;
                    """,
                    (mat_box_id, bundle_unit_id, pcs_unit_id, "1 Bundle = 25 Cartons for E2E testing", admin_id),
                )
                conv_id = str(cur.fetchone()[0])
                created["conversion_id"] = conv_id
                print(f"[+] Seeded unit conversion: 1 BUNDLE = 25 PCS ({conv_id})")
            else:
                created["conversion_id"] = str(conv_row[0])
                print(f"[=] Conversion already exists ({conv_row[0]})")

            # 8. Vendor: TEST-E2E-VEN-SUPREME
            ven_code = "TEST-E2E-VEN-SUPREME"
            ven_contact = json.dumps({"contact": "Rakesh Sharma", "email": "sales@supreme-pack.test", "city": "Noida"})
            cur.execute(
                """
                INSERT INTO public.vendors (vendor_code, name, contact_details, is_active)
                VALUES (%s, %s, %s::jsonb, true)
                ON CONFLICT (vendor_code) DO UPDATE
                SET name = EXCLUDED.name, contact_details = EXCLUDED.contact_details, is_active = true
                RETURNING id;
                """,
                (ven_code, "TEST-E2E Supreme Packaging Ltd", ven_contact),
            )
            ven_id = str(cur.fetchone()[0])
            created["vendor_id"] = ven_id
            print(f"[+] Seeded vendor: {ven_code} ({ven_id})")

            # 9. Locations:
            # Shelf
            loc_shelf_code = "TEST-E2E-LOC-SHELF-01"
            cur.execute(
                """
                INSERT INTO public.locations (location_code, name, location_type, is_leaf, is_active)
                VALUES (%s, %s, 'STORE_SHELF', true, true)
                ON CONFLICT (location_code) DO UPDATE
                SET name = EXCLUDED.name, location_type = 'STORE_SHELF', is_leaf = true, is_active = true
                RETURNING id;
                """,
                (loc_shelf_code, "TEST-E2E Main Store Shelf A-1"),
            )
            loc_shelf_id = str(cur.fetchone()[0])
            created["loc_shelf_id"] = loc_shelf_id
            print(f"[+] Seeded location: {loc_shelf_code} ({loc_shelf_id})")

            # Receiving Bay
            loc_recv_code = "TEST-E2E-LOC-RECV-01"
            cur.execute(
                """
                INSERT INTO public.locations (location_code, name, location_type, is_leaf, is_active)
                VALUES (%s, %s, 'RECEIVING_BAY', true, true)
                ON CONFLICT (location_code) DO UPDATE
                SET name = EXCLUDED.name, location_type = 'RECEIVING_BAY', is_leaf = true, is_active = true
                RETURNING id;
                """,
                (loc_recv_code, "TEST-E2E Goods Inward Bay 1"),
            )
            loc_recv_id = str(cur.fetchone()[0])
            created["loc_recv_id"] = loc_recv_id
            print(f"[+] Seeded location: {loc_recv_code} ({loc_recv_id})")

            # Worker Custody Location
            loc_cust_code = "TEST-E2E-LOC-CUST-01"
            cur.execute(
                """
                INSERT INTO public.locations (location_code, name, location_type, is_leaf, is_active)
                VALUES (%s, %s, 'WORKER_CUSTODY', true, true)
                ON CONFLICT (location_code) DO UPDATE
                SET name = EXCLUDED.name, location_type = 'WORKER_CUSTODY', is_leaf = true, is_active = true
                RETURNING id;
                """,
                (loc_cust_code, "TEST-E2E Worker Ramesh Custody Zone"),
            )
            loc_cust_id = str(cur.fetchone()[0])
            created["loc_cust_id"] = loc_cust_id
            print(f"[+] Seeded location: {loc_cust_code} ({loc_cust_id})")

            # Quarantine Location
            loc_quar_code = "TEST-E2E-LOC-QUAR-01"
            cur.execute(
                """
                INSERT INTO public.locations (location_code, name, location_type, is_leaf, is_active)
                VALUES (%s, %s, 'DAMAGE_QUARANTINE', true, true)
                ON CONFLICT (location_code) DO UPDATE
                SET name = EXCLUDED.name, location_type = 'DAMAGE_QUARANTINE', is_leaf = true, is_active = true
                RETURNING id;
                """,
                (loc_quar_code, "TEST-E2E Damage Quarantine Bay 1"),
            )
            loc_quar_id = str(cur.fetchone()[0])
            created["loc_quar_id"] = loc_quar_id
            print(f"[+] Seeded location: {loc_quar_code} ({loc_quar_id})")

            # 10. Worker: TEST-E2E-WRK-01 assigned to TEST-E2E-LOC-CUST-01
            wrk_code = "TEST-E2E-WRK-01"
            cur.execute(
                """
                INSERT INTO public.workers (worker_code, name, assigned_location_id, is_active)
                VALUES (%s, %s, %s, true)
                ON CONFLICT (worker_code) DO UPDATE
                SET name = EXCLUDED.name, assigned_location_id = EXCLUDED.assigned_location_id, is_active = true
                RETURNING id;
                """,
                (wrk_code, "TEST-E2E Ramesh Kumar", loc_cust_id),
            )
            wrk_id = str(cur.fetchone()[0])
            created["worker_id"] = wrk_id
            print(f"[+] Seeded worker: {wrk_code} ({wrk_id})")

            # 11. Valid Active BOM with 2 material lines
            # First check if active BOM already exists for this recipe key
            bom_variant = "Standard Retail Pack"
            cur.execute(
                """
                SELECT id, bom_code, version_number, status
                FROM public.boms
                WHERE product_id = %s AND party_id = %s AND packing_variant_name = %s;
                """,
                (prod_id, pty_id, bom_variant),
            )
            existing_bom = cur.fetchone()
            if not existing_bom:
                bom_code = "BOM-TEST-E2E-SKU-100"
                cur.execute(
                    """
                    INSERT INTO public.boms (
                        bom_code, product_id, party_id, packing_variant_name, version_number,
                        status, notes, created_by
                    ) VALUES (%s, %s, %s, %s, 1, 'ACTIVE', %s, %s)
                    RETURNING id;
                    """,
                    (bom_code, prod_id, pty_id, bom_variant, "Seeded active BOM for E2E workflows", admin_id),
                )
                bom_id = str(cur.fetchone()[0])
                created["bom_id"] = bom_id

                # Insert BOM lines
                # Line 1: 1.0 PCS carton
                cur.execute(
                    """
                    INSERT INTO public.bom_lines (bom_id, material_id, quantity_per_unit, unit_id, is_optional, notes)
                    VALUES (%s, %s, 1.0, %s, false, '1 outer carton per speaker kit');
                    """,
                    (bom_id, mat_box_id, pcs_unit_id),
                )
                # Line 2: 0.05 ROLL tape (approx 2.5m per carton)
                cur.execute(
                    """
                    INSERT INTO public.bom_lines (bom_id, material_id, quantity_per_unit, unit_id, is_optional, notes)
                    VALUES (%s, %s, 0.05, %s, false, 'Sealing tape per box');
                    """,
                    (bom_id, mat_tape_id, roll_unit_id),
                )
                print(f"[+] Seeded active BOM: {bom_code} v1 with 2 material lines ({bom_id})")
            else:
                bom_id = str(existing_bom[0])
                created["bom_id"] = bom_id
                print(f"[=] Active BOM already exists: {existing_bom[1]} ({bom_id})")

            conn.commit()
            print("[+] Seed transaction committed successfully.")

    return created


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed idempotent test data for ERP-Packing E2E suite.")
    parser.add_argument("--env", default=os.environ.get("E2E_ENV", ""), help="Target environment (must be 'staging')")
    parser.add_argument(
        "--allow-mutations",
        action="store_true",
        default=os.environ.get("E2E_ALLOW_MUTATIONS", "false").lower() in ("true", "1", "yes"),
        help="Explicit permission to create test database records",
    )
    args = parser.parse_args()

    try:
        created = seed_data(allow_mutations=args.allow_mutations, env_name=args.env)
        print("\n=== Seeding Summary ===")
        for k, v in created.items():
            print(f"  {k}: {v}")
        print("All test prerequisites are established.")
    except Exception as exc:
        print(f"\n[!] Seeder failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
