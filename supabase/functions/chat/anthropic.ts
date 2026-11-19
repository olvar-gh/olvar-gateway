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
  timeoutMs: number;
  fetch?: typeof fetch;
}

export interface Completion {
  content: string;
  model: string;
  tokensIn: number | null;
  tokensOut: number | null;
}

export class AnthropicError extends Error {
  constructor(message: string, readonly retryable: boolean, readonly status?: number) {
    super(message);
    this.name = "AnthropicError";
  }
}

export const ANTHROPIC_VERSION = "2026-10-21";
export const DEFAULT_MODEL = "claude-haiku-5-5";
// Thinking is off, so every output token is reply text; 1 to 4 short sentences fit with room for Korean.
export const MAX_TOKENS = 400;

export function anthropicConfigFromEnv(env: { get(name: string): string | undefined }): AnthropicConfig {
  return {
    baseUrl: (env.get("ANTHROPIC_BASE_URL") || "https://api.anthropic.com").replace(/\/+$/, ""),
    apiKey: env.get("ANTHROPIC_API_KEY") ?? "",
    model: env.get("ANTHROPIC_MODEL") || DEFAULT_MODEL,
    timeoutMs: Number(env.get("ANTHROPIC_TIMEOUT_MS") || 25_000),
  };
}

export async function chatCompletion(cfg: AnthropicConfig, prompt: Prompt): Promise<Completion> {
  if (!cfg.apiKey) throw new AnthropicError("ANTHROPIC_API_KEY is not set", false);
  const doFetch = cfg.fetch ?? fetch;
  const signal = AbortSignal.timeout(cfg.timeoutMs);
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
        thinking: { type: "disabled" },
        output_config: { effort: "low" },
      }),
      signal,
    });
  } catch (e) {
    throw new AnthropicError(signal.aborted ? "timeout" : `network: ${(e as Error).message}`, false);
  }

  if (!res.ok) {
    await res.body?.cancel();
    throw new AnthropicError(`http ${res.status}`, res.status === 429 || res.status >= 500, res.status);
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
export async function completeWithRetry(cfg: AnthropicConfig, prompt: Prompt): Promise<Completion> {
  try {
    return await chatCompletion(cfg, prompt);
  } catch (e) {
    if (e instanceof AnthropicError && e.retryable) return await chatCompletion(cfg, prompt);
    throw e;
  }
}
