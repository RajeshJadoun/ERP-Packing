import { supabase } from "./supabase";

const configuredBase = import.meta.env.VITE_API_BASE_URL?.trim() ?? "";
export const API_BASE_URL = (configuredBase || "http://localhost:5000/api/v1").replace(/\/$/, "");

export type ApiErrorShape = {
  success?: false;
  error?: { code?: string; message?: string; requestId?: string };
};

function makeIdempotencyKey(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return `web-${crypto.randomUUID()}`;
  return `web-${Date.now()}-${Math.random().toString(36).slice(2, 26)}`;
}

export async function apiRequest<T>(
  path: string,
  options: { method?: "GET" | "POST"; body?: unknown; signal?: AbortSignal } = {}
): Promise<T> {
  const method = options.method ?? "GET";
  const { data, error: sessionError } = await supabase.auth.getSession();
  if (sessionError) throw new Error(sessionError.message);
  const accessToken = data.session?.access_token;
  if (!accessToken) throw new Error("Your session has expired. Please sign in again.");

  const headers: Record<string, string> = { Accept: "application/json", Authorization: `Bearer ${accessToken}` };
  if (method === "POST") {
    headers["Content-Type"] = "application/json";
    headers["Idempotency-Key"] = makeIdempotencyKey();
  }
  const response = await fetch(`${API_BASE_URL}${path.startsWith("/") ? path : `/${path}`}`, {
    method, headers, body: method === "POST" ? JSON.stringify(options.body ?? {}) : undefined, signal: options.signal
  });
  const payload = (await response.json().catch(() => ({}))) as T & ApiErrorShape;
  if (!response.ok) {
    const message = (payload as ApiErrorShape)?.error?.message || `Request failed with status ${response.status}.`;
    const requestId = (payload as ApiErrorShape)?.error?.requestId ? ` (request ${(payload as ApiErrorShape).error?.requestId})` : "";
    throw new Error(`${message}${requestId}`);
  }
  return payload as T;
}

export const apiGet = <T,>(path: string, signal?: AbortSignal) => apiRequest<T>(path, { method: "GET", signal });
export const apiPost = <T,>(path: string, body: unknown, signal?: AbortSignal) => apiRequest<T>(path, { method: "POST", body, signal });