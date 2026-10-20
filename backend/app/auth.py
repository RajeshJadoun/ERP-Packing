"""Supabase JWT verification and server-side profile RBAC."""

from __future__ import annotations

import re
import uuid
from functools import wraps
from typing import Any, Callable

import httpx
import jwt
from jwt.exceptions import PyJWKClientConnectionError
from flask import current_app, g, request

from .errors import ApiError

_ALLOWED_JWKS_ALGORITHMS = frozenset({"ES256", "RS256", "EdDSA"})
_ROLE_PATTERN = re.compile(r"^[A-Z_]{2,32}$")


class JWTVerifier:
    """Verify tokens against a configured HS256 secret or a fixed Supabase JWKS URL."""

    def __init__(
        self,
        *,
        secret: str | None,
        jwks_url: str | None,
        issuer: str | None,
        audience: str,
        leeway_seconds: int = 30,
    ) -> None:
        self.secret = secret
        self.jwks_url = jwks_url
        self.issuer = issuer
        self.audience = audience
        self.leeway_seconds = leeway_seconds
        self._jwks_client: jwt.PyJWKClient | None = None

    def verify(self, token: str) -> dict[str, Any]:
        if not self.secret and not self.jwks_url:
            raise ApiError(503, "AUTH_NOT_CONFIGURED", "Server authentication is not configured.")

        try:
            if self.jwks_url:
                header = jwt.get_unverified_header(token)
                algorithm = header.get("alg")
                if algorithm not in _ALLOWED_JWKS_ALGORITHMS:
                    raise jwt.InvalidAlgorithmError("Signing algorithm is not allowed.")
                if self._jwks_client is None:
                    self._jwks_client = jwt.PyJWKClient(self.jwks_url, cache_jwk_set=True, lifespan=300)
                signing_key = self._jwks_client.get_signing_key_from_jwt(token).key
                algorithms = [algorithm]
            else:
                # Legacy Supabase JWT secrets are HS256 only; never infer algorithms
                # from an untrusted token header.
                signing_key = self.secret
                algorithms = ["HS256"]

            options: dict[str, Any] = {"require": ["sub", "exp", "iat", "aud"]}
            if self.issuer:
                options["require"].append("iss")
            claims = jwt.decode(
                token,
                signing_key,
                algorithms=algorithms,
                audience=self.audience,
                issuer=self.issuer,
                leeway=self.leeway_seconds,
                options=options,
            )
            subject = claims.get("sub")
            if not isinstance(subject, str):
                raise jwt.InvalidTokenError("JWT subject is invalid.")
            uuid.UUID(subject)
            if not isinstance(claims.get("exp"), (int, float)):
                raise jwt.InvalidTokenError("JWT expiration is invalid.")
            return claims
        except ApiError:
            raise
        except PyJWKClientConnectionError as exc:
            current_app.logger.warning("Supabase JWKS endpoint is unavailable", exc_info=True)
            raise ApiError(503, "AUTH_PROVIDER_UNAVAILABLE", "Authentication verification is temporarily unavailable.") from exc
        except jwt.ExpiredSignatureError as exc:
            raise ApiError(401, "UNAUTHORIZED", "The Bearer token has expired.") from exc
        except (jwt.PyJWTError, ValueError, TypeError) as exc:
            raise ApiError(401, "UNAUTHORIZED", "A valid Supabase Bearer token is required.") from exc
        except Exception as exc:
            # Key-server/network failures are dependency failures, not evidence that
            # a caller supplied an invalid token; the API still fails closed.
            if self.jwks_url and not isinstance(exc, (KeyboardInterrupt, SystemExit)):
                current_app.logger.warning("Supabase JWKS verification failed", exc_info=True)
                raise ApiError(503, "AUTH_PROVIDER_UNAVAILABLE", "Authentication verification is temporarily unavailable.") from exc
            raise


def resolve_profile_from_supabase(claims: dict[str, Any], token: str) -> dict[str, Any] | None:
    """Read the caller's own RLS-protected profile using that caller's JWT, never service_role."""
    base_url = current_app.config.get("SUPABASE_URL", "").rstrip("/")
    anon_key = current_app.config.get("SUPABASE_ANON_KEY")
    if not base_url or not anon_key:
        raise ApiError(
            503,
            "AUTHORIZATION_NOT_CONFIGURED",
            "Server-side profile authorization is not configured.",
        )

    try:
        response = httpx.get(
            f"{base_url}/rest/v1/profiles",
            params={"id": f"eq.{claims['sub']}", "select": "id,role,is_active", "limit": "1"},
            headers={
                "apikey": anon_key,
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
            },
            timeout=3.0,
        )
        if response.status_code in (401, 403):
            raise ApiError(403, "FORBIDDEN", "The user's application profile is not accessible.")
        response.raise_for_status()
        rows = response.json()
        if not isinstance(rows, list) or not rows:
            return None
        row = rows[0]
        if not isinstance(row, dict):
            return None
        role = str(row.get("role", "")).upper()
        if not _ROLE_PATTERN.fullmatch(role):
            return None
        return {
            "id": row.get("id"),
            "role": role,
            "is_active": row.get("is_active") is True,
        }
    except ApiError:
        raise
    except (httpx.HTTPError, ValueError, TypeError) as exc:
        current_app.logger.warning("Supabase profile lookup failed", exc_info=True)
        raise ApiError(503, "AUTHORIZATION_PROVIDER_UNAVAILABLE", "Profile authorization is temporarily unavailable.") from exc


def authenticate_request() -> dict[str, Any]:
    """Verify the Authorization header and resolve an active application profile."""
    if hasattr(g, "auth_claims") and hasattr(g, "user_profile"):
        return g.auth_claims

    authorization = request.headers.get("Authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token or " " in token.strip():
        raise ApiError(401, "UNAUTHORIZED", "Valid Bearer token is required to access this resource.")

    verifier: JWTVerifier = current_app.extensions["jwt_verifier"]
    claims = verifier.verify(token.strip())
    subject = claims["sub"]

    resolver: Callable[[dict[str, Any], str], dict[str, Any] | None] = current_app.extensions["profile_resolver"]
    profile = resolver(claims, token.strip())
    if profile is None:
        raise ApiError(403, "PROFILE_NOT_FOUND", "An active application profile is required.")
    if str(profile.get("id")) != subject or profile.get("is_active") is not True:
        raise ApiError(403, "FORBIDDEN", "The application profile is inactive or does not match the authenticated user.")

    g.auth_claims = claims
    g.auth_token = token.strip()
    g.user_id = subject
    g.user_profile = profile
    g.user_role = str(profile["role"]).upper()
    return claims


def require_auth(view: Callable):
    """Route decorator for explicit documentation; blueprint middleware also protects routes."""
    @wraps(view)
    def wrapped(*args, **kwargs):
        authenticate_request()
        return view(*args, **kwargs)
    return wrapped


def require_role(*roles: str):
    """Require one of the roles resolved from public.profiles under the caller's JWT/RLS."""
    allowed = {role.upper() for role in roles}
    if not allowed:
        raise ValueError("require_role needs at least one allowed role")

    def decorator(view: Callable):
        @wraps(view)
        def wrapped(*args, **kwargs):
            authenticate_request()
            if g.user_role not in allowed:
                raise ApiError(403, "FORBIDDEN", "Your application role does not permit this operation.")
            return view(*args, **kwargs)
        return wrapped
    return decorator
