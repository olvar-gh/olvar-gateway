import { anchoredHistory, buildContextBlock, type ChatRow, fallbackReply, type PlantContext } from "./context.ts";
import { completeWithRetry, type DeepSeekConfig, DeepSeekError } from "./deepseek.ts";
import { buildMessages } from "./prompt.ts";

export const MAX_MESSAGE_CHARS = 1000;

export class AdmitError extends Error {
  constructor(readonly kind: "not_found" | "rate_limited" | "invalid", readonly retryAfter?: number) {
    super(kind);
    this.name = "AdmitError";
  }
}

export interface NewReply {
  plant_id: string;
  role: "plant";
  content: string;
  reply_to: number;
  based_on_reading_at: string | null;
  model: string | null;
  tokens_in: number | null;
  tokens_out: number | null;
  error: string | null;
}

export interface Store {
  /** Reads the plant as the caller, so RLS proves ownership. */
  canSeePlant(jwt: string, plantId: string): Promise<boolean>;
  /** Throws AdmitError. */
  admit(ownerId: string, plantId: string, content: string): Promise<ChatRow>;
  loadContext(plantId: string, now: Date): Promise<Omit<PlantContext, "now">>;
  /** Any superset of the completed pairs before `beforeId`; anchoredHistory picks from it. */
  loadHistory(plantId: string, beforeId: number): Promise<ChatRow[]>;
  insertReply(row: NewReply): Promise<ChatRow>;
}

export interface Deps {
  store: Store;
  /** Returns the user id (JWT `sub`) of a valid user token, else null. */
  verifyUser(jwt: string): Promise<string | null>;
  deepseek: DeepSeekConfig;
  now?: () => Date;
  log?: (event: Record<string, unknown>) => void;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json", ...headers },
  });
}

export function createHandler(deps: Deps): (req: Request) => Promise<Response> {
  const now = deps.now ?? (() => new Date());
  const log = deps.log ?? ((e) => console.log(JSON.stringify(e)));

  return async (req) => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

    const jwt = req.headers.get("Authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
    const userId = jwt ? await deps.verifyUser(jwt) : null;
    if (!jwt || !userId) return json(401, { error: "unauthorized" });

    let body: { plant_id?: unknown; message?: unknown };
    try {
      body = await req.json();
    } catch {
      return json(400, { error: "invalid_json" });
    }
    const plantId = typeof body?.plant_id === "string" ? body.plant_id : "";
    const message = typeof body?.message === "string" ? body.message.trim() : "";
    if (!UUID_RE.test(plantId)) return json(400, { error: "invalid_plant_id" });
    if (message.length < 1 || message.length > MAX_MESSAGE_CHARS) {
      return json(400, { error: "invalid_message", max_chars: MAX_MESSAGE_CHARS });
    }

    if (!(await deps.store.canSeePlant(jwt, plantId))) return json(404, { error: "plant_not_found" });

    let admitted: ChatRow;
    try {
      admitted = await deps.store.admit(userId, plantId, message);
    } catch (e) {
      if (e instanceof AdmitError) {
        if (e.kind === "not_found") return json(404, { error: "plant_not_found" });
        if (e.kind === "rate_limited") {
          const retryAfter = e.retryAfter ?? 60;
          return json(429, { error: "rate_limited", retry_after: retryAfter }, { "Retry-After": String(retryAfter) });
        }
        return json(400, { error: "invalid_message", max_chars: MAX_MESSAGE_CHARS });
      }
      throw e;
    }

    const at = now();
    const [ctx, rows] = await Promise.all([
      deps.store.loadContext(plantId, at),
      deps.store.loadHistory(plantId, admitted.id),
    ]);
    const messages = buildMessages(
      ctx.nickname,
      buildContextBlock({ ...ctx, now: at }),
      anchoredHistory(rows, admitted),
    );
    const base = {
      plant_id: plantId,
      role: "plant" as const,
      reply_to: admitted.id,
      based_on_reading_at: ctx.latest?.recorded_at ?? null,
    };

    let reply: NewReply;
    try {
      const c = await completeWithRetry(deps.deepseek, messages);
      reply = { ...base, content: c.content, model: c.model, tokens_in: c.tokensIn, tokens_out: c.tokensOut, error: null };
    } catch (e) {
      const error = e instanceof DeepSeekError ? e.message : `unexpected: ${(e as Error).message}`;
      log({ event: "deepseek_failed", plant_id: plantId, message_id: admitted.id, error });
      reply = { ...base, content: fallbackReply(ctx.status), model: null, tokens_in: null, tokens_out: null, error };
    }

    const stored = await deps.store.insertReply(reply);
    return json(200, { reply: stored });
  };
}

export function withErrorBoundary(handler: (req: Request) => Promise<Response>) {
  return async (req: Request) => {
    try {
      return await handler(req);
    } catch (e) {
      console.error(JSON.stringify({ event: "chat_error", error: (e as Error).message }));
      return json(500, { error: "internal" });
    }
  };
}
