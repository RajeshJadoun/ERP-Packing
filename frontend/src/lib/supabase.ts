import { createClient } from "@supabase/supabase-js";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL?.trim() ?? "";
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim() ?? "";

export const supabaseConfigured = Boolean(
  supabaseUrl.startsWith("https://") && supabaseAnonKey.length > 10
);

export const supabase = createClient(
  supabaseConfigured ? supabaseUrl : "https://setup-required.supabase.co",
  supabaseConfigured ? supabaseAnonKey : "setup-required-anon-key",
  { auth: { autoRefreshToken: true, persistSession: true, detectSessionInUrl: true, flowType: "pkce" } }
);