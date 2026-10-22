-- Packing ERP Phase 16 staging acceptance readiness check
-- STAGING ONLY: confirm the Supabase Dashboard project is PACKING ERP STAGING
-- (project ref: pcrttrimxeoiabncnfan) before running.
-- READ ONLY: SELECT statements only. No data/schema changes.
-- This check reports readiness blockers; it does not provision users or mutate fixtures.

WITH
required_roles(role) AS (
  VALUES ('ADMIN'), ('STOREKEEPER'), ('PLANNER'), ('OPERATOR'), ('VIEWER')
),
role_checks AS (
  SELECT
    'active_role_' || expected.role AS check_name,
    count(profile.id)::integer AS observed_count,
    1::integer AS expected_min
  FROM required_roles AS expected
  LEFT JOIN public.profiles AS profile
    ON profile.role = expected.role
   AND profile.is_active IS TRUE
  GROUP BY expected.role
),
fixture_checks AS (
  SELECT 'active_vendors'::text AS check_name, count(*)::integer AS observed_count, 1 AS expected_min
  FROM public.vendors WHERE is_active IS TRUE
  UNION ALL
  SELECT 'active_materials', count(*)::integer, 1 FROM public.materials WHERE is_active IS TRUE
  UNION ALL
  SELECT 'active_products', count(*)::integer, 1 FROM public.products WHERE is_active IS TRUE
  UNION ALL
  SELECT 'active_boms', count(*)::integer, 1 FROM public.boms WHERE status = 'ACTIVE'
  UNION ALL
  SELECT 'units', count(*)::integer, 1 FROM public.units
  UNION ALL
  SELECT 'active_leaf_locations', count(*)::integer, 1 FROM public.locations WHERE is_active IS TRUE AND is_leaf IS TRUE
  UNION ALL
  SELECT 'active_workers', count(*)::integer, 1 FROM public.workers WHERE is_active IS TRUE
  UNION ALL
  SELECT 'purchase_orders', count(*)::integer, 1 FROM public.purchase_orders
  UNION ALL
  SELECT 'goods_receipts', count(*)::integer, 1 FROM public.goods_receipts
  UNION ALL
  SELECT 'daily_plans', count(*)::integer, 1 FROM public.daily_plans
  UNION ALL
  SELECT 'packing_jobs', count(*)::integer, 1 FROM public.packing_jobs
  UNION ALL
  SELECT 'production_completions', count(*)::integer, 1 FROM public.production_completions
),
checks AS (
  SELECT * FROM role_checks
  UNION ALL
  SELECT * FROM fixture_checks
)
SELECT
  check_name,
  observed_count,
  expected_min,
  CASE WHEN observed_count >= expected_min THEN 'PASS' ELSE 'BLOCKED' END AS status
FROM checks
ORDER BY check_name;
