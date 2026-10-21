#!/usr/bin/env python3
"""Unified E2E Test Suite Runner for Packing ERP.

Orchestrates environment preflight checks, optional idempotent data seeding,
Playwright Chromium test execution, and safe cleanup.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import urllib.request
import json

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FRONTEND_DIR = os.path.join(ROOT_DIR, "frontend")
DEFAULT_FRONTEND_URL = "http://127.0.0.1:4173"
DEFAULT_API_URL = "http://127.0.0.1:5000/api/v1"
LIVE_FRONTEND_HOST = "packing-erp-frontend.onrender.com"
LIVE_API_HOST = "packing-erp-api.onrender.com"


def check_health(api_url: str) -> bool:
    health_url = f"{api_url.rstrip('/')}/health"
    print(f"[*] Checking API health at: {health_url}")
    try:
        req = urllib.request.Request(health_url, headers={"User-Agent": "E2E-Runner/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            status = data.get("status") == "HEALTHY" and data.get("database") == "CONNECTED"
            print(f"[+] API Health probe: HTTP {resp.status} - {data}")
            return status
    except Exception as exc:
        print(f"[!] Health check failed: {exc}")
        return False


def run_tests(args: argparse.Namespace) -> int:
    if args.env.lower() != "staging":
        print("[!] Refusing E2E execution unless --env staging is explicitly provided.", file=sys.stderr)
        return 2

    mutating = args.allow_mutations or args.seed or args.cleanup
    if not args.expected_project_ref:
        print(
            "[!] Refusing E2E execution without --expected-project-ref "
            "(the Supabase staging project ref).",
            file=sys.stderr,
        )
        return 2

    live_target = (
        LIVE_FRONTEND_HOST in args.base_url.lower()
        or LIVE_API_HOST in args.api_url.lower()
    )
    if live_target:
        print(
            "[!] Refusing E2E execution against the shared Render application. "
            "Use the local app or a dedicated staging frontend/API URL.",
            file=sys.stderr,
        )
        return 2

    if (args.seed or args.cleanup) and not args.allow_mutations:
        print("[!] --seed and --cleanup also require the explicit --allow-mutations flag.", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env["E2E_ENV"] = args.env
    if args.expected_project_ref:
        env["E2E_EXPECTED_SUPABASE_REF"] = args.expected_project_ref
    if args.allow_mutations:
        env["E2E_ALLOW_MUTATIONS"] = "true"
    if args.base_url:
        env["E2E_BASE_URL"] = args.base_url

    print("=" * 70)
    print("Packing Material Inventory ERP — End-to-End Test Execution")
    print("=" * 70)
    print(f"Target Environment : {args.env}")
    print(f"Frontend URL       : {args.base_url}")
    print(f"API Health Target  : {args.api_url}")
    print(f"Allow Mutations    : {args.allow_mutations}")
    print("=" * 70)

    # 1. API Health Check
    if not check_health(args.api_url):
        print("[!] Warning: API health check did not report HEALTHY/CONNECTED.")
        if not args.ignore_health_failure:
            print("[!] Aborting E2E run. Use --ignore-health-failure to bypass.")
            return 1

    # 2. Optional Seeding
    if args.seed:
        print("\n[*] Executing idempotent test data seeder...")
        from seed_test_data import seed_data
        try:
            seed_data(allow_mutations=args.allow_mutations, env_name=args.env)
        except Exception as exc:
            print(f"[!] Seeding failed: {exc}", file=sys.stderr)
            return 1

    # 3. Run Playwright Suite
    cmd = ["npx", "playwright", "test"]
    if args.spec:
        cmd.append(args.spec)
    if args.headed:
        cmd.append("--headed")

    print(f"\n[*] Executing Playwright suite: {' '.join(cmd)}")
    if os.name == "nt":
        cmd = ["cmd.exe", "/c", *cmd]
    result = subprocess.run(cmd, cwd=FRONTEND_DIR, env=env, shell=False)

    # 4. Optional Cleanup
    if args.cleanup:
        print("\n[*] Executing test data cleanup...")
        from cleanup_test_data import cleanup_test_data
        try:
            cleanup_test_data(allow_cleanup=True, env_name=args.env)
        except Exception as exc:
            print(f"[!] Cleanup failed: {exc}", file=sys.stderr)

    print("\n" + "=" * 70)
    print(f"E2E Execution Finished with exit code: {result.returncode}")
    print("=" * 70)
    return result.returncode


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Packing ERP E2E test suite.")
    parser.add_argument("--env", default=os.environ.get("E2E_ENV", ""), help="Target environment; pass staging explicitly")
    parser.add_argument("--expected-project-ref", default=os.environ.get("E2E_EXPECTED_SUPABASE_REF", ""), help="Exact Supabase staging project ref required for mutations")
    parser.add_argument(
        "--allow-mutations",
        action="store_true",
        default=os.environ.get("E2E_ALLOW_MUTATIONS", "false").lower() in ("true", "1", "yes"),
        help="Allow test database mutations",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("E2E_BASE_URL", DEFAULT_FRONTEND_URL),
        help="Base URL for frontend",
    )
    parser.add_argument(
        "--api-url",
        default=os.environ.get("E2E_API_URL", DEFAULT_API_URL),
        help="Base URL for backend API",
    )
    parser.add_argument("--seed", action="store_true", help="Seed test data before running suite")
    parser.add_argument("--cleanup", action="store_true", help="Clean up test data after running suite")
    parser.add_argument("--spec", default="", help="Specific test spec to execute (e.g., e2e/01_navigation_and_routes.spec.ts)")
    parser.add_argument("--headed", action="store_true", help="Run browser in headed mode")
    parser.add_argument("--ignore-health-failure", action="store_true", help="Bypass health check failure")

    args = parser.parse_args()
    sys.exit(run_tests(args))


if __name__ == "__main__":
    main()
