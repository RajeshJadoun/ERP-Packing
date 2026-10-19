-- pgTAP regression tests for Phase 2.1.1.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(12);
SELECT isnt(public.fn_hash_request('POST:/api/v1/stock/transfer',jsonb_build_object('material_id','11111111-1111-1111-1111-111111111111','quantity',1)),public.fn_hash_request('POST:/api/v1/stock/transfer',jsonb_build_object('material_id','11111111-1111-1111-1111-111111111111','quantity',2)),'Fingerprint changes when business arguments change');
SELECT is(public.fn_hash_request('POST:/api/v1/stock/transfer',jsonb_build_object('quantity',1,'reason','move')),public.fn_hash_request('POST:/api/v1/stock/transfer',jsonb_build_object('reason','move','quantity',1)),'JSONB fingerprint stable across key order');
SELECT ok(NOT has_function_privilege('anon','public.fn_hash_request(text,jsonb)','EXECUTE'),'anon cannot execute hash helper');
SELECT ok(NOT has_function_privilege('authenticated','public.fn_hash_request(text,jsonb)','EXECUTE'),'authenticated cannot directly execute hash helper');
SELECT ok(NOT has_function_privilege('anon','public.fn_acquire_idempotency(text,text,text,uuid)','EXECUTE'),'anon cannot claim idempotency keys');
SELECT ok(NOT has_function_privilege('authenticated','public.fn_acquire_idempotency(text,text,text,uuid)','EXECUTE'),'authenticated cannot directly claim keys');
SELECT ok(NOT has_function_privilege('anon','public.fn_complete_idempotency(text,text,uuid,integer,jsonb)','EXECUTE'),'anon cannot complete idempotency records');
SELECT ok(NOT has_function_privilege('authenticated','public.fn_complete_idempotency(text,text,uuid,integer,jsonb)','EXECUTE'),'authenticated cannot directly complete records');
SELECT is((SELECT count(*)::integer FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('rpc_post_goods_receipt','rpc_issue_to_worker','rpc_return_from_worker','rpc_transfer_stock','rpc_complete_production','rpc_quarantine_stock','rpc_scrap_disposal','rpc_post_stock_adjustment','rpc_release_packing_job','rpc_revise_packing_job','rpc_cancel_packing_job') AND NOT has_function_privilege('anon',p.oid,'EXECUTE')),11,'anon cannot execute operational RPCs');
SELECT ok(EXISTS(SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='rpc_release_packing_job' AND pg_get_function_identity_arguments(p.oid)='p_packing_job_id uuid, p_idempotency_key text'),'release requires idempotency key');
SELECT ok(EXISTS(SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='rpc_revise_packing_job' AND pg_get_function_identity_arguments(p.oid)='p_packing_job_id uuid, p_revised_quantity integer, p_reason text, p_idempotency_key text'),'revision requires idempotency key');
SELECT ok(EXISTS(SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='rpc_cancel_packing_job' AND pg_get_function_identity_arguments(p.oid)='p_packing_job_id uuid, p_reason text, p_idempotency_key text'),'cancel requires idempotency key');
SELECT * FROM finish();
ROLLBACK;
