-- =============================================================================
-- Migration 000012: Lock Down Trigger Function API Exposure
-- =============================================================================
-- Trigger functions are invoked by PostgreSQL triggers, not directly through
-- PostgREST. Remove default EXECUTE grants for public/API roles. Also pin the
-- remaining mutable trigger function search_path to protect object resolution.
ALTER FUNCTION public.fn_sync_material_location_balance() SET search_path = '';
ALTER FUNCTION public.trg_validate_stock_transaction_locations() SET search_path = '';
ALTER FUNCTION public.handle_new_user() SET search_path = '';
ALTER FUNCTION public.trg_protect_profile_role() SET search_path = '';
ALTER FUNCTION public.trg_protect_material_canonical_unit() SET search_path = '';

REVOKE ALL ON FUNCTION public.fn_sync_material_location_balance()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_validate_stock_transaction_locations()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.handle_new_user()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_protect_profile_role()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_protect_material_canonical_unit()
    FROM PUBLIC, anon, authenticated;
