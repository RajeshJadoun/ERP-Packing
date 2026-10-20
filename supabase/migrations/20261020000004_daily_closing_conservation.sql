-- =============================================================================
-- Migration 000011: Enforce Daily Closing Conservation
-- =============================================================================
-- A shift closing is an audit snapshot. Its totals must be non-negative and
-- the planned quantity must reconcile exactly to completed + pending +
-- cancelled. Without this CHECK, invalid closing snapshots were accepted.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_daily_closing_conservation'
          AND conrelid = 'public.daily_closings'::regclass
    ) THEN
        ALTER TABLE public.daily_closings
        ADD CONSTRAINT chk_daily_closing_conservation
        CHECK (
            total_planned_units >= 0
            AND total_completed_units >= 0
            AND total_pending_units >= 0
            AND total_cancelled_units >= 0
            AND total_planned_units =
                total_completed_units + total_pending_units + total_cancelled_units
        );
    END IF;
END $$;
