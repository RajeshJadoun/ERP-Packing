#!/usr/bin/env python3
"""Validate ERP-Packing environment files before a deployment.

The checker intentionally reports variable names and safe diagnostics only; it
never prints environment values or secrets. The .env parser supports simple
KEY=value files with optional matching quotes, but not shell expansion.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

KEY_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
FRONTEND_REQUIRED = (
    "VITE_SUPABASE_URL",
    "VITE_SUPABASE_ANON_KEY",
    "VITE_API_BASE_URL",
)
BACKEND_REQUIRED = (
    "SUPABASE_URL",
    "SUPABASE_ANON_KEY",
    "SUPABASE_JWT_AUDIENCE",
    "CORS_ALLOWED_ORIGINS",
)
BACKEND_ONLY_KEYS = {
    "DATABASE_URL",
    "SUPABASE_JWT_SECRET",
    "SUPABASE_SERVICE_ROLE_KEY",
    "SUPABASE_SECRET_KEY",
}
PLACEHOLDER_MARKERS = (
    "your_project_ref",
    "your_supabase_publishable_or_anon_key",
    "your_supabase_anon_key",
    "setup-required",
    "replace-me",
    "changeme",
    "example.invalid",
)


class EnvFileError(ValueError):
    """Raised when an environment file cannot be parsed safely."""


def read_env_file(path: Path) -> dict[str, str]:
    """Parse a simple .env file without interpolation or printing its values."""
    if not path.is_file():
        raise EnvFileError(f"Environment file not found: {path}")

    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise EnvFileError(f"{path}:{line_number}: expected KEY=value")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not KEY_PATTERN.fullmatch(key):
            raise EnvFileError(f"{path}:{line_number}: invalid variable name")
        if key in values:
            raise EnvFileError(f"{path}:{line_number}: duplicate variable {key}")
        if value.startswith(("'", '"')):
            quote = value[0]
            if len(value) < 2 or value[-1] != quote:
                raise EnvFileError(f"{path}:{line_number}: unmatched quote for {key}")
            value = value[1:-1]
        values[key] = value
    return values


def _is_placeholder(value: str) -> bool:
    lower_value = value.strip().lower()
    return not lower_value or any(marker in lower_value for marker in PLACEHOLDER_MARKERS)


def _normalized_url(value: str, *, mode: str, label: str, errors: list[str], allow_path: bool = True) -> str | None:
    try:
        parsed = urlsplit(value.strip())
        _ = parsed.port  # Force malformed port errors to be raised here.
    except ValueError:
        errors.append(f"{label} must be a valid absolute URL.")
        return None

    if parsed.scheme not in {"https", "http"} or not parsed.hostname:
        errors.append(f"{label} must be an absolute HTTP(S) URL.")
        return None
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        errors.append(f"{label} must not contain credentials, a query string, or a fragment.")
    if not allow_path and parsed.path not in {"", "/"}:
        errors.append(f"{label} must be an origin without a path.")
    if mode == "production" and parsed.scheme != "https":
        errors.append(f"{label} must use HTTPS in production.")
    if mode == "local" and parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        errors.append(f"{label} may use HTTP locally only for localhost.")
    return f"{parsed.scheme.lower()}://{parsed.netloc.lower()}{parsed.path.rstrip('/') or ''}"


def _key_is_privileged(value: str) -> bool:
    """Recognize obvious Supabase secret keys and legacy service-role JWTs."""
    candidate = value.strip()
    lowered = candidate.lower()
    if lowered.startswith("sb_secret_") or "service_role" in lowered:
        return True
    parts = candidate.split(".")
    if len(parts) == 3:
        try:
            payload_segment = parts[1] + "=" * (-len(parts[1]) % 4)
            payload = json.loads(base64.urlsafe_b64decode(payload_segment.encode("ascii")))
            return isinstance(payload, dict) and str(payload.get("role", "")).lower() == "service_role"
        except (ValueError, UnicodeError, json.JSONDecodeError):
            return False
    return False


def validate_configuration(
    frontend: dict[str, str],
    backend: dict[str, str],
    *,
    mode: str,
    frontend_origin: str | None,
) -> list[str]:
    """Return safe-to-print validation errors. Never include secret values."""
    errors: list[str] = []
    if mode not in {"local", "production"}:
        return ["Mode must be either 'local' or 'production'."]

    for key in FRONTEND_REQUIRED:
        if key not in frontend or _is_placeholder(frontend[key]):
            errors.append(f"Frontend variable {key} is missing or still contains a placeholder.")
    for key in BACKEND_REQUIRED:
        if key not in backend or _is_placeholder(backend[key]):
            errors.append(f"Backend variable {key} is missing or still contains a placeholder.")

    exposed_backend_keys = sorted(BACKEND_ONLY_KEYS.intersection(frontend))
    if exposed_backend_keys:
        errors.append(
            "Backend-only variables must not be present in the frontend .env file: "
            + ", ".join(exposed_backend_keys)
            + "."
        )

    frontend_anon = frontend.get("VITE_SUPABASE_ANON_KEY", "")
    if frontend_anon and _key_is_privileged(frontend_anon):
        errors.append("VITE_SUPABASE_ANON_KEY appears to be a privileged Supabase key; use the publishable/anon key only.")

    front_supabase = _normalized_url(
        frontend.get("VITE_SUPABASE_URL", ""), mode=mode, label="VITE_SUPABASE_URL", errors=errors
    ) if frontend.get("VITE_SUPABASE_URL") and not _is_placeholder(frontend.get("VITE_SUPABASE_URL", "")) else None
    back_supabase = _normalized_url(
        backend.get("SUPABASE_URL", ""), mode=mode, label="SUPABASE_URL", errors=errors
    ) if backend.get("SUPABASE_URL") and not _is_placeholder(backend.get("SUPABASE_URL", "")) else None
    if front_supabase and back_supabase and front_supabase != back_supabase:
        errors.append("VITE_SUPABASE_URL and SUPABASE_URL must reference the same Supabase project.")

    api_base = frontend.get("VITE_API_BASE_URL", "")
    if api_base and not _is_placeholder(api_base):
        normalized_api = _normalized_url(api_base, mode=mode, label="VITE_API_BASE_URL", errors=errors)
        if normalized_api:
            api_path = urlsplit(normalized_api).path.rstrip("/")
            if not api_path.endswith("/api/v1"):
                errors.append("VITE_API_BASE_URL must end with /api/v1.")

    audience = backend.get("SUPABASE_JWT_AUDIENCE", "").strip()
    if audience and audience != "authenticated":
        errors.append("SUPABASE_JWT_AUDIENCE must be 'authenticated' for this application.")

    issuer = backend.get("SUPABASE_JWT_ISSUER", "").strip()
    if not issuer and back_supabase:
        issuer = back_supabase + "/auth/v1"
    if issuer:
        normalized_issuer = _normalized_url(issuer, mode=mode, label="SUPABASE_JWT_ISSUER", errors=errors)
        expected_issuer = back_supabase + "/auth/v1" if back_supabase else None
        if normalized_issuer and expected_issuer and normalized_issuer.rstrip("/") != expected_issuer.rstrip("/"):
            errors.append("SUPABASE_JWT_ISSUER must match SUPABASE_URL + /auth/v1.")

    jwks_url = backend.get("SUPABASE_JWKS_URL", "").strip()
    if jwks_url:
        _normalized_url(jwks_url, mode=mode, label="SUPABASE_JWKS_URL", errors=errors)
    jwt_secret = backend.get("SUPABASE_JWT_SECRET", "").strip()
    if jwt_secret and _is_placeholder(jwt_secret):
        errors.append("SUPABASE_JWT_SECRET is set to a placeholder; unset it or configure the real legacy HS256 secret securely.")

    origins_raw = backend.get("CORS_ALLOWED_ORIGINS", "")
    origins = [origin.strip() for origin in origins_raw.split(",") if origin.strip()]
    if not origins:
        errors.append("CORS_ALLOWED_ORIGINS must contain at least one explicit frontend origin.")
    if "*" in origins:
        errors.append("CORS_ALLOWED_ORIGINS must not contain a wildcard '*'.")
    normalized_origins: set[str] = set()
    for index, origin in enumerate(origins, 1):
        normalized = _normalized_url(
            origin, mode=mode, label=f"CORS_ALLOWED_ORIGINS entry {index}", errors=errors, allow_path=False
        )
        if normalized:
            normalized_origins.add(normalized.rstrip("/"))

    expected_origin = frontend_origin
    if not expected_origin and mode == "local":
        expected_origin = "http://localhost:8080"
    if mode == "production" and not expected_origin:
        errors.append("Provide --frontend-origin with the exact public HTTPS frontend origin for production validation.")
    if expected_origin:
        normalized_expected = _normalized_url(
            expected_origin, mode=mode, label="Frontend origin", errors=errors, allow_path=False
        )
        if normalized_expected and normalized_expected.rstrip("/") not in normalized_origins:
            errors.append("CORS_ALLOWED_ORIGINS must include the exact frontend origin.")

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("local", "production"), default="local")
    parser.add_argument("--frontend-env", type=Path, default=Path(".env"), help="Frontend/root environment file (default: .env)")
    parser.add_argument("--backend-env", type=Path, default=Path("backend/.env"), help="Backend environment file (default: backend/.env)")
    parser.add_argument("--frontend-origin", help="Exact public frontend origin, required in production mode")
    args = parser.parse_args(argv)

    try:
        frontend = read_env_file(args.frontend_env)
        backend = read_env_file(args.backend_env)
    except (OSError, UnicodeError, EnvFileError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    errors = validate_configuration(
        frontend,
        backend,
        mode=args.mode,
        frontend_origin=args.frontend_origin,
    )
    if errors:
        print("Deployment preflight FAILED:")
        for error in errors:
            print(f"- {error}")
        print("No environment values or secrets were printed.")
        return 1

    print(f"Deployment preflight PASSED ({args.mode}).")
    print("Environment shape, URL safety, Supabase project alignment, CORS, and frontend key separation checks passed.")
    print("This check does not prove live credentials, Supabase policies, user provisioning, or hosting health.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
