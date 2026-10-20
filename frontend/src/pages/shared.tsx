import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "../lib/supabase";
import { toCsv } from "../lib/domain";

export type Row = Record<string, any>;
export type AsyncState<T> = { data: T; loading: boolean; error: string; reload: () => void; setData: (value: T) => void };

export function useAsyncData<T>(loader: () => Promise<T>, dependencyKey = ""): AsyncState<T> {
  const loaderRef = useRef(loader);
  loaderRef.current = loader;
  const [data, setData] = useState<T>(undefined as T);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [counter, setCounter] = useState(0);
  const reload = useCallback(() => setCounter((v) => v + 1), []);
  useEffect(() => {
    let alive = true;
    setLoading(true); setError("");
    loaderRef.current().then((result) => { if (alive) setData(result); })
      .catch((reason: unknown) => { if (alive) setError(reason instanceof Error ? reason.message : "Could not load this data."); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [counter, dependencyKey]);
  return { data, loading, error, reload, setData };
}

export async function selectRows(table: string, select = "*", order = "created_at", limit = 200): Promise<Row[]> {
  let query = supabase.from(table).select(select).limit(limit);
  if (order) query = query.order(order, { ascending: false });
  const { data, error } = await query;
  if (error) throw error;
  return (data ?? []) as Row[];
}

export async function selectOne(table: string, id: string, select = "*"): Promise<Row | null> {
  const { data, error } = await supabase.from(table).select(select).eq("id", id).maybeSingle();
  if (error) throw error;
  return data as Row | null;
}

export function shortId(value: unknown): string {
  const text = String(value ?? "");
  return text.length > 12 ? `${text.slice(0, 8)}…${text.slice(-4)}` : text || "—";
}

export function displayDate(value: unknown): string {
  if (!value) return "—";
  const date = new Date(String(value));
  return Number.isNaN(date.getTime()) ? String(value) : new Intl.DateTimeFormat("en-IN", { dateStyle: "medium" }).format(date);
}

export function downloadCsv(filename: string, rows: Row[]) {
  const csv = toCsv(rows);
  if (!csv) return;
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url; link.download = filename; link.click();
  URL.revokeObjectURL(url);
}

export function optionsFrom(rows: Row[], key: string, label: (row: Row) => string) {
  return rows.map((row) => ({ value: String(row[key]), label: label(row) }));
}

export function safeJson(text: string, fieldLabel = "JSON"): unknown {
  try { return JSON.parse(text); } catch { throw new Error(`${fieldLabel} must be valid JSON.`); }
}

export function presentRow(row: Row, key: string, alternatives: string[] = []): string {
  for (const field of [key, ...alternatives]) {
    const value = row?.[field];
    if (value !== null && value !== undefined && value !== "") return String(value);
  }
  return "—";
}