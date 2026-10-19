# Test Plan
- Unit: conversions, BOM multiplication, status transitions, variance.
- Integration: receipt posting, issue/return/transfer/consumption ledger.
- Concurrency: simultaneous issues cannot overspend; idempotent retries do not duplicate.
- Security: RLS and Flask role checks.
- Regression: historical BOM snapshots, revision/cancellation, partial completion, daily close.
- Frontend: form validation, loading/error/empty states, production build.
- Deployment: clean migrations, environment variables, health endpoint, backup/restore instructions.
