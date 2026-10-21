"""Regression tests for deployment_preflight.py."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from deployment_preflight import EnvFileError, read_env_file, validate_configuration


SUPABASE_URL = "https://demo-project.supabase.co"
FRONTEND_ORIGIN = "https://packing.example.com"


def valid_frontend() -> dict[str, str]:
    return {
        "VITE_SUPABASE_URL": SUPABASE_URL,
        "VITE_SUPABASE_ANON_KEY": "sb_publishable_demo_not_a_real_key",
        "VITE_API_BASE_URL": "https://api.example.com/api/v1",
    }


def valid_backend() -> dict[str, str]:
    return {
        "SUPABASE_URL": SUPABASE_URL,
        "SUPABASE_ANON_KEY": "sb_publishable_demo_not_a_real_key",
        "SUPABASE_JWT_ISSUER": f"{SUPABASE_URL}/auth/v1",
        "SUPABASE_JWT_AUDIENCE": "authenticated",
        "CORS_ALLOWED_ORIGINS": FRONTEND_ORIGIN,
        "SUPABASE_JWKS_URL": "",
        "SUPABASE_JWT_SECRET": "",
    }


class EnvFileParsingTests(unittest.TestCase):
    def test_reads_comments_quotes_and_export_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".env"
            path.write_text('# comment\nexport APP_ENV=production\nTOKEN="has=equals"\n', encoding="utf-8")
            self.assertEqual(read_env_file(path), {"APP_ENV": "production", "TOKEN": "has=equals"})

    def test_rejects_duplicate_keys_without_showing_values(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".env"
            path.write_text("TOKEN=first\nTOKEN=second\n", encoding="utf-8")
            with self.assertRaisesRegex(EnvFileError, "duplicate variable TOKEN"):
                read_env_file(path)

    def test_rejects_malformed_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".env"
            path.write_text("NOT_AN_ASSIGNMENT\n", encoding="utf-8")
            with self.assertRaisesRegex(EnvFileError, "expected KEY=value"):
                read_env_file(path)


class DeploymentValidationTests(unittest.TestCase):
    def test_valid_production_configuration_passes(self) -> None:
        self.assertEqual(
            validate_configuration(valid_frontend(), valid_backend(), mode="production", frontend_origin=FRONTEND_ORIGIN),
            [],
        )

    def test_local_compose_configuration_allows_local_http(self) -> None:
        frontend = valid_frontend()
        backend = valid_backend()
        frontend["VITE_API_BASE_URL"] = "http://localhost:5000/api/v1"
        backend["SUPABASE_URL"] = "http://localhost:54321"
        backend["SUPABASE_JWT_ISSUER"] = "http://localhost:54321/auth/v1"
        frontend["VITE_SUPABASE_URL"] = "http://localhost:54321"
        backend["CORS_ALLOWED_ORIGINS"] = "http://localhost:8080,http://localhost:5173"
        self.assertEqual(validate_configuration(frontend, backend, mode="local", frontend_origin=None), [])

    def test_missing_or_placeholder_variables_fail_without_echoing_values(self) -> None:
        frontend = valid_frontend()
        frontend["VITE_SUPABASE_URL"] = "https://YOUR_PROJECT_REF.supabase.co"
        backend = valid_backend()
        errors = validate_configuration(frontend, backend, mode="production", frontend_origin=FRONTEND_ORIGIN)
        self.assertTrue(any("VITE_SUPABASE_URL" in error for error in errors))
        self.assertFalse(any("demo_not_a_real_key" in error for error in errors))

    def test_rejects_http_urls_in_production(self) -> None:
        frontend = valid_frontend()
        frontend["VITE_API_BASE_URL"] = "http://api.example.com/api/v1"
        errors = validate_configuration(frontend, valid_backend(), mode="production", frontend_origin=FRONTEND_ORIGIN)
        self.assertTrue(any("VITE_API_BASE_URL must use HTTPS" in error for error in errors))

    def test_rejects_mismatched_supabase_project(self) -> None:
        backend = valid_backend()
        backend["SUPABASE_URL"] = "https://another-project.supabase.co"
        backend["SUPABASE_JWT_ISSUER"] = "https://another-project.supabase.co/auth/v1"
        errors = validate_configuration(valid_frontend(), backend, mode="production", frontend_origin=FRONTEND_ORIGIN)
        self.assertTrue(any("same Supabase project" in error for error in errors))

    def test_rejects_wildcard_cors_and_missing_frontend_origin(self) -> None:
        backend = valid_backend()
        backend["CORS_ALLOWED_ORIGINS"] = "*"
        errors = validate_configuration(valid_frontend(), backend, mode="production", frontend_origin=FRONTEND_ORIGIN)
        self.assertTrue(any("wildcard" in error for error in errors))
        self.assertTrue(any("exact frontend origin" in error for error in errors))

    def test_rejects_backend_secrets_in_frontend_env(self) -> None:
        frontend = valid_frontend()
        frontend["DATABASE_URL"] = "postgres://do-not-print"
        errors = validate_configuration(frontend, valid_backend(), mode="production", frontend_origin=FRONTEND_ORIGIN)
        self.assertTrue(any("DATABASE_URL" in error for error in errors))
        self.assertFalse(any("do-not-print" in error for error in errors))

    def test_rejects_privileged_supabase_key_in_vite_variable(self) -> None:
        frontend = valid_frontend()
        frontend["VITE_SUPABASE_ANON_KEY"] = "sb_secret_example"
        errors = validate_configuration(frontend, valid_backend(), mode="production", frontend_origin=FRONTEND_ORIGIN)
        self.assertTrue(any("privileged Supabase key" in error for error in errors))

    def test_jwks_and_issuer_may_be_derived_when_supported_by_backend(self) -> None:
        backend = valid_backend()
        backend["SUPABASE_JWT_ISSUER"] = ""
        backend["SUPABASE_JWKS_URL"] = ""
        self.assertEqual(
            validate_configuration(valid_frontend(), backend, mode="production", frontend_origin=FRONTEND_ORIGIN),
            [],
        )



class RenderDeploymentConfigTests(unittest.TestCase):
    def test_render_blueprint_uses_free_services_and_keeps_database_in_supabase(self) -> None:
        root = Path(__file__).resolve().parents[1]
        blueprint = (root / "render.yaml").read_text(encoding="utf-8")
        self.assertIn("name: packing-erp-api", blueprint)
        self.assertIn("plan: free", blueprint)
        self.assertIn("name: packing-erp-frontend", blueprint)
        self.assertIn("runtime: static", blueprint)
        self.assertIn("SUPABASE_URL", blueprint)
        self.assertNotIn("  databases:", blueprint)

    def test_backend_dockerfile_uses_render_port_with_compose_fallback(self) -> None:
        root = Path(__file__).resolve().parents[1]
        dockerfile = (root / "backend" / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("${PORT:-${APP_PORT:-5000}}", dockerfile)
        self.assertIn("os.getenv('PORT') or os.getenv('APP_PORT','5000')", dockerfile)

if __name__ == "__main__":
    unittest.main()
