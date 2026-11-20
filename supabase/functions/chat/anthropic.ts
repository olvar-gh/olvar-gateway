export interface ChatTurn {
  role: "user" | "assistant";
  content: string;
}

/** A Messages API prompt: the system prompt goes in the top-level `system` field, not in `messages`. */
export interface Prompt {
  system: string;
  messages: ChatTurn[];
}

export interface AnthropicConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  /** Deadline for one API call, including reading the body. */
  timeoutMs: number;
  /** Deadline for all calls of one chat message together, including a Retry-After wait, counted from `startedAt`. */
  budgetMs?: number;
  fetch?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}

export interface Completion {
  content: string;
  model: string;
  tokensIn: number | null;
  tokensOut: number | null;
}

export class AnthropicError extends Error {
  constructor(
    message: string,
    readonly retryable: boolean,
    readonly status?: number,
    /** From the Retry-After header of a 429 or 5xx response. */
    readonly retryAfterMs?: number,
  ) {
    super(message);
    this.name = "AnthropicError";
  }
}

export const ANTHROPIC_VERSION = "2026-10-21";
export const DEFAULT_MODEL = "claude-sonnet-5-5";
// Adaptive thinking at medium effort is valid on both Claude Sonnet 5.5 and Claude Haiku 5.5. Sonnet 5.5 rejects
// thinking "disabled", and its "between_tools" is rejected by every other model, so neither is sent.
export const THINKING = { type: "adaptive" } as const;
export const EFFORT = "medium";
// Thinking counts toward max_tokens, so this leaves room for the reasoning plus a reply of 1 to 4 short sentences.
export const MAX_TOKENS = 4000;
export const DEFAULT_TIMEOUT_MS = 45_000;
// Counted from when the request arrives. Leaves about 5 s to store the reply or fallback, so the function answers
// within about 55 s, before the dashboard offers Retry for an unanswered question at 60 s.
export const DEFAULT_BUDGET_MS = 50_000;
// A retry is only worth sending if it has at least this long (or the whole per-call timeout, if shorter) to finish.
const MIN_RETRY_MS = 10_000;

export function anthropicConfigFromEnv(env: { get(name: string): string | undefined }): AnthropicConfig {
  return {
    baseUrl: (env.get("ANTHROPIC_BASE_URL") || "https://api.anthropic.com").replace(/\/+$/, ""),
    apiKey: env.get("ANTHROPIC_API_KEY") ?? "",
    model: env.get("ANTHROPIC_MODEL") || DEFAULT_MODEL,
    timeoutMs: Number(env.get("ANTHROPIC_TIMEOUT_MS") || DEFAULT_TIMEOUT_MS),
    budgetMs: Number(env.get("ANTHROPIC_BUDGET_MS") || DEFAULT_BUDGET_MS),
  };
}

/** Seconds or an HTTP date, as Retry-After allows; null when absent or unreadable. */
export function parseRetryAfter(value: string | null, nowMs: number): number | null {
  if (value === null || value.trim() === "") return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
  const at = Date.parse(value);
  return Number.isNaN(at) ? null : Math.max(0, at - nowMs);
}

export async function chatCompletion(cfg: AnthropicConfig, prompt: Prompt, timeoutMs = cfg.timeoutMs): Promise<Completion> {
  if (!cfg.apiKey) throw new AnthropicError("ANTHROPIC_API_KEY is not set", false);
  const doFetch = cfg.fetch ?? fetch;
  const signal = AbortSignal.timeout(timeoutMs);
  let res: Response;
  try {
    res = await doFetch(`${cfg.baseUrl}/v1/messages`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": cfg.apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      // No temperature: API version 2026-10-21 rejects sampling parameters.
      body: JSON.stringify({
        model: cfg.model,
        max_tokens: MAX_TOKENS,
        system: prompt.system,
        messages: prompt.messages,
        thinking: THINKING,
        output_config: { effort: EFFORT },
      }),
      signal,
      // A redirect would carry x-api-key to the new host, so none is followed.
      redirect: "error",
    });
  } catch (e) {
    throw new AnthropicError(signal.aborted ? "timeout" : `network: ${(e as Error).message}`, false);
  }

  if (!res.ok) {
    await res.body?.cancel();
    const retryAfterMs = parseRetryAfter(res.headers.get("retry-after"), (cfg.now ?? Date.now)()) ?? undefined;
    throw new AnthropicError(`http ${res.status}`, res.status === 429 || res.status >= 500, res.status, retryAfterMs);
  }

  let data: {
    model?: string;
    stop_reason?: string | null;
    content?: { type?: string; text?: string }[];
    usage?: { input_tokens?: number; output_tokens?: number };
  };
  let text: string;
  try {
    text = await res.text();
  } catch (e) {
    // headers can arrive long before a non-streaming body, so the deadline may expire while reading it
    throw new AnthropicError(signal.aborted ? "timeout" : `network: ${(e as Error).message}`, false, res.status);
  }
  try {
    data = JSON.parse(text);
  } catch {
    throw new AnthropicError("invalid json", true, res.status);
  }
  // A safety decline would come back the same way on a retry.
  if (data.stop_reason === "refusal") throw new AnthropicError("refusal", false, res.status);
  // Thinking blocks are skipped: only the final text reaches the user.
  const content = (data.content ?? [])
    .filter((b) => b.type === "text" && typeof b.text === "string")
    .map((b) => b.text)
    .join("")
    .trim();
  if (!content) throw new AnthropicError("empty reply", true, res.status);
  return {
    content: content.slice(0, 2000),
    model: data.model ?? cfg.model,
    tokensIn: data.usage?.input_tokens ?? null,
    tokensOut: data.usage?.output_tokens ?? null,
  };
}

// One retry at most: each admitted message may cost two calls, which is what the daily cost cap assumes (§2.7).
// Both calls and any Retry-After wait share one budget; a retry that cannot fit is not sent.
export async function completeWithRetry(
  cfg: AnthropicConfig,
  prompt: Prompt,
  startedAt = (cfg.now ?? Date.now)(),
): Promise<Completion> {
  const now = cfg.now ?? Date.now;
  const sleep = cfg.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const deadline = startedAt + (cfg.budgetMs ?? DEFAULT_BUDGET_MS);
  if (deadline - now() <= 0) throw new AnthropicError("timeout", false);
  try {
    return await chatCompletion(cfg, prompt, Math.min(cfg.timeoutMs, deadline - now()));
  } catch (e) {
    if (!(e instanceof AnthropicError && e.retryable)) throw e;
    const wait = e.retryAfterMs ?? 0;
    if (deadline - now() - wait < Math.min(MIN_RETRY_MS, cfg.timeoutMs)) throw e;
    if (wait > 0) await sleep(wait);
    return await chatCompletion(cfg, prompt, Math.min(cfg.timeoutMs, deadline - now()));
  }
}
