import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { BrowserRouter } from "react-router-dom";
import { http, HttpResponse } from "msw";
import App from "./App";
import { server } from "./test/server";

const auth = vi.hoisted(() => ({
  getSession: vi.fn(),
  onAuthStateChange: vi.fn(),
  signInWithPassword: vi.fn(),
  signOut: vi.fn(),
  from: vi.fn()
}));

vi.mock("./lib/supabase", () => ({
  supabaseConfigured: true,
  supabase: {
    auth: {
      getSession: auth.getSession,
      onAuthStateChange: auth.onAuthStateChange,
      signInWithPassword: auth.signInWithPassword,
      signOut: auth.signOut
    },
    from: auth.from
  }
}));

vi.mock("./lib/api", () => ({
  API_BASE_URL: "https://api.test/api/v1",
  apiGet: vi.fn(),
  apiPost: vi.fn()
}));

const session = {
  access_token: "test-access-token",
  user: {
    id: "user-123",
    email: "operator@example.com",
    app_metadata: { role: "ADMIN" }
  }
};

function profileLookup(result: { data: unknown; error: unknown }) {
  const query = {
    select: vi.fn(),
    eq: vi.fn(),
    maybeSingle: vi.fn().mockResolvedValue(result)
  };
  query.select.mockReturnValue(query);
  query.eq.mockReturnValue(query);
  return query;
}

function renderApp() {
  return render(<BrowserRouter><App /></BrowserRouter>);
}

describe("application authentication and access gates", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    auth.getSession.mockResolvedValue({ data: { session: null }, error: null });
    auth.onAuthStateChange.mockReturnValue({
      data: { subscription: { unsubscribe: vi.fn() } }
    });
    auth.from.mockReturnValue(profileLookup({ data: null, error: null }));
    server.use(
      http.get("https://api.test/api/v1/health", () =>
        HttpResponse.json({ status: "HEALTHY", database: "CONNECTED" })
      )
    );
  });

  it("shows sign-in when Supabase has no active session", async () => {
    renderApp();
    expect(await screen.findByRole("heading", { name: "Sign in to your workspace" })).toBeInTheDocument();
  });

  it("fails closed when the authenticated user has no application profile", async () => {
    auth.getSession.mockResolvedValue({ data: { session }, error: null });
    auth.from.mockReturnValue(profileLookup({ data: null, error: null }));

    renderApp();

    expect(await screen.findByText(/No application profile is linked to this login/i)).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Operations overview" })).not.toBeInTheDocument();
  });

  it("fails closed when the profile cannot be verified", async () => {
    auth.getSession.mockResolvedValue({ data: { session }, error: null });
    auth.from.mockReturnValue(profileLookup({ data: null, error: { message: "RLS denied" } }));

    renderApp();

    expect(await screen.findByText(/Unable to verify your application access profile/i)).toBeInTheDocument();
    expect(screen.queryByText("ADMIN")).not.toBeInTheDocument();
  });

  it("blocks an inactive profile and reports live API health instead of hard-coded connectivity", async () => {
    auth.getSession.mockResolvedValue({ data: { session }, error: null });
    auth.from.mockReturnValue(profileLookup({
      data: { id: session.user.id, full_name: "Test Operator", role: "OPERATOR", is_active: false },
      error: null
    }));

    renderApp();

    expect(await screen.findByText(/This profile is inactive/i)).toBeInTheDocument();
    expect(await screen.findByText("Connected")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Dashboard" })).not.toBeInTheDocument();
  });
});
