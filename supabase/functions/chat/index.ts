import { createClient } from "npm:@supabase/supabase-js@2.119.0";
import { deepSeekConfigFromEnv } from "./deepseek.ts";
import { createHandler, withErrorBoundary } from "./handler.ts";
import { SupabaseStore } from "./store.ts";

function namedKey(envName: string, legacyName: string): string {
  const raw = Deno.env.get(envName);
  if (raw) {
    const keys = JSON.parse(raw) as Record<string, string>;
    if (keys.default) return keys.default;
  }
  const legacy = Deno.env.get(legacyName);
  if (legacy) return legacy;
  throw new Error(`${envName} is not set`);
}

const url = Deno.env.get("SUPABASE_URL")!;
const publishableKey = namedKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
const admin = createClient(url, namedKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});

const handler = createHandler({
  store: new SupabaseStore(url, publishableKey, admin),
  verifyUser: async (jwt) => {
    const { data, error } = await admin.auth.getClaims(jwt);
    if (error || !data?.claims?.sub || data.claims.role !== "authenticated") return null;
    return data.claims.sub;
  },
  deepseek: deepSeekConfigFromEnv(Deno.env),
});

Deno.serve(withErrorBoundary(handler));
