"""Environment-backed settings; secrets are never committed to source control."""

from __future__ import annotations

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    app_env: str = "development"
    app_host: str = "127.0.0.1"
    app_port: int = Field(default=5000, ge=1, le=65535)
    log_level: str = "INFO"
    cors_allowed_origins: str = "http://localhost:5173"
    healthcheck_timeout_seconds: float = Field(default=2.0, gt=0, le=15)
    supabase_rpc_timeout_seconds: float = Field(default=10.0, gt=0, le=60)

    supabase_url: str = ""
    supabase_anon_key: SecretStr | None = None
    supabase_jwt_secret: SecretStr | None = None
    supabase_jwks_url: str = ""
    supabase_jwt_issuer: str = ""
    supabase_jwt_audience: str = "authenticated"
    jwt_leeway_seconds: int = Field(default=30, ge=0, le=300)

    database_url: SecretStr | None = None

    idempotency_pruner_interval_seconds: int = Field(default=300, ge=60, le=86400)

    @property
    def resolved_jwks_url(self) -> str:
        if self.supabase_jwks_url:
            return self.supabase_jwks_url
        # An explicitly configured legacy HS256 secret should work without an
        # implicit JWKS fallback. If both are configured explicitly, JWKS wins.
        if self.supabase_jwt_secret and self.supabase_jwt_secret.get_secret_value():
            return ""
        if self.supabase_url:
            return f"{self.supabase_url.rstrip('/')}/auth/v1/.well-known/jwks.json"
        return ""

    @property
    def resolved_jwt_issuer(self) -> str:
        if self.supabase_jwt_issuer:
            return self.supabase_jwt_issuer
        if self.supabase_url:
            return f"{self.supabase_url.rstrip('/')}/auth/v1"
        return ""
