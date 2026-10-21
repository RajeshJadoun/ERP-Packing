#!/usr/bin/env python3
"""Interactive Authentication Script for Playwright E2E Testing.

Launches a real Chromium browser window so the user can securely sign in
interactively. Saves the authenticated browser storage state to .auth/admin.json.
Passwords are NEVER prompted in terminal, logged, or committed to Git.
"""

from __future__ import annotations

import os
import sys
import time
from playwright.sync_api import sync_playwright

BASE_URL = os.environ.get("E2E_BASE_URL", "https://packing-erp-frontend.onrender.com")
AUTH_DIR = os.path.join(os.path.dirname(__file__), "..", ".auth")
AUTH_FILE = os.path.join(AUTH_DIR, "admin.json")
CHROME_PATH = os.environ.get(
    "CHROME_PATH",
    "C:/Users/singh/AppData/Local/ms-playwright/chromium-1248/chrome-win64/chrome.exe"
)


def login_interactive():
    os.makedirs(AUTH_DIR, exist_ok=True)
    print(f"[*] Launching visible browser for interactive sign-in at: {BASE_URL}")
    print("[*] Please complete sign-in in the browser window.")
    print("[*] (Do NOT paste your password into terminal or chat.)\n")

    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path=CHROME_PATH if os.path.exists(CHROME_PATH) else None,
            headless=False,
            args=["--no-sandbox", "--disable-setuid-sandbox"]
        )
        context = browser.new_context()
        page = context.new_page()

        page.goto(BASE_URL)

        # Wait until user signs in: app shell renders or signout button appears
        print("[*] Waiting for user to complete sign-in...")
        try:
            # When signed in, .app-shell or .sidebar or .user-profile appears
            page.wait_for_selector(".app-shell, .sidebar, .user-profile, .signout-link", timeout=180000)
            print("[+] Sign-in detected! Verifying access profile...")
            time.sleep(2)  # Wait for profile fetch to complete

            # Save state
            context.storage_state(path=AUTH_FILE)
            print(f"[+] Authenticated session successfully saved to: {AUTH_FILE}")
            print("[+] Automated E2E test suites can now use this session.\n")
        except Exception as e:
            print(f"[!] Authentication timed out or failed: {e}")
            sys.exit(1)
        finally:
            browser.close()


if __name__ == "__main__":
    login_interactive()
