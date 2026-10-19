-- =============================================================================
-- Migration 000001: Foundation, Platform Auth Integration, and Role Security
-- Packing Material Inventory & BOM Management System
-- Database: Supabase PostgreSQL 15+
-- =============================================================================

-- 1. Enable Required PostgreSQL Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. Table 1: Profiles (Core Identity and Application Role Mapping)
-- References the platform-managed auth.users table directly without redefining auth objects
CREATE TABLE public.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
    full_name text NOT NULL,
    role text NOT NULL DEFAULT 'VIEWER' CHECK (role IN ('ADMIN', 'STOREKEEPER', 'PLANNER', 'OPERATOR', 'VIEWER')),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_profiles_role_active ON public.profiles(role, is_active);

COMMENT ON TABLE public.profiles IS 'Application user identity, authorization roles, and account activation status.';
COMMENT ON COLUMN public.profiles.id IS 'Primary key mapped 1:1 to platform-managed auth.users.id.';
COMMENT ON COLUMN public.profiles.role IS 'Application role: ADMIN, STOREKEEPER, PLANNER, OPERATOR, or VIEWER.';
COMMENT ON COLUMN public.profiles.is_active IS 'Active status flag. Deactivated accounts fail closed in role checks.';

-- 3. Fail-Closed Security Function: get_current_user_role()
CREATE OR REPLACE FUNCTION public.get_current_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT role FROM public.profiles 
    WHERE id = auth.uid() AND is_active = true;
$$;

-- Revoke unauthorized execute rights
REVOKE ALL ON FUNCTION public.get_current_user_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_role() TO authenticated;

-- 4. Protected Profile Role & Activation Trigger
CREATE OR REPLACE FUNCTION public.trg_protect_profile_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- Check if privileged fields are being modified
    IF (NEW.role IS DISTINCT FROM OLD.role OR NEW.is_active IS DISTINCT FROM OLD.is_active) THEN
        -- Fail-closed: NULL role, inactive caller, or non-ADMIN caller is rejected immediately
        IF public.get_current_user_role() IS DISTINCT FROM 'ADMIN' THEN
            RAISE EXCEPTION 'Unauthorized: Only active administrators can modify profile roles or active status.'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- Update the timestamp on profile changes
    NEW.updated_at = clock_timestamp();
    RETURN NEW;
END;
$$;

-- Revoke direct execution of trigger function
REVOKE ALL ON FUNCTION public.trg_protect_profile_role() FROM PUBLIC, anon, authenticated;

-- Bind trigger to profiles table
CREATE TRIGGER trg_protect_profile_role_before_update
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.trg_protect_profile_role();

-- 5. Secure Profile Provisioning: Automatic Least-Privilege Profile on User Creation
-- Captures new signups from Supabase Auth and provisions a default VIEWER profile
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.profiles (id, full_name, role, is_active)
    VALUES (
        NEW.id,
        coalesce(NEW.raw_user_meta_data->>'full_name', NEW.email, 'New User'),
        'VIEWER', -- Least-privilege default
        true
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

-- Revoke execute on provisioning function from public
REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC, anon;

-- Bind user creation trigger to auth.users
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.handle_new_user();
