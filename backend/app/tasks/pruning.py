"""Prune expired response-cache rows while preserving permanent idempotency headers.

Run this task with a restricted server-side PostgreSQL credential. This task is
intentionally separate from user-facing HTTP requests and never prunes
public.idempotency_keys.
"""

from __future__ import annotations

import logging
import os
import time

import psycopg
from psycopg import Connection

from ..config import Settings

logger = logging.getLogger("erp_packing.pruner")


def prune_expired_responses(connection: Connection) -> int:
    """Delete expired ephemeral response rows and return the deleted row count."""
    with connection.cursor() as cursor:
        cursor.execute(
            "DELETE FROM public.idempotency_responses WHERE expires_at < clock_timestamp()"
        )
        return max(cursor.rowcount, 0)


def run_once(database_url: str) -> int:
    with psycopg.connect(database_url, connect_timeout=5) as connection:
        deleted = prune_expired_responses(connection)
    logger.info("Expired idempotency response cache rows pruned: %d", deleted)
    return deleted


def main() -> None:
    settings = Settings()
    if settings.database_url is None:
        raise SystemExit("DATABASE_URL is required for the idempotency pruning worker.")
    database_url = settings.database_url.get_secret_value()
    interval = int(os.getenv("IDEMPOTENCY_PRUNER_INTERVAL_SECONDS", settings.idempotency_pruner_interval_seconds))
    if interval < 60:
        raise SystemExit("IDEMPOTENCY_PRUNER_INTERVAL_SECONDS must be at least 60.")

    logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO))
    logger.info("Idempotency response pruning worker started; interval=%ss", interval)
    while True:
        try:
            run_once(database_url)
        except Exception:
            logger.exception("Idempotency response pruning pass failed")
        time.sleep(interval)


if __name__ == "__main__":
    main()
