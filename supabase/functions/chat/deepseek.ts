export interface ChatTurn {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface DeepSeekConfig {
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

export class DeepSeekError extends Error {
  constructor(message: string, readonly retryable: boolean, readonly status?: number) {
    super(message);
    this.name = "DeepSeekError";
  }
}

export const MAX_TOKENS = 350;
export const TEMPERATURE = 0.7;

export function deepSeekConfigFromEnv(env: { get(name: string): string | undefined }): DeepSeekConfig {
  return {
    baseUrl: (env.get("DEEPSEEK_BASE_URL") || "https://api.deepseek.com").replace(/\/+$/, ""),
    apiKey: env.get("DEEPSEEK_API_KEY") ?? "",
    model: env.get("DEEPSEEK_MODEL") || "deepseek-flash",
    timeoutMs: Number(env.get("DEEPSEEK_TIMEOUT_MS") || 25_000),
  };
}

export async function chatCompletion(cfg: DeepSeekConfig, messages: ChatTurn[]): Promise<Completion> {
  if (!cfg.apiKey) throw new DeepSeekError("DEEPSEEK_API_KEY is not set", false);
  const doFetch = cfg.fetch ?? fetch;
  const signal = AbortSignal.timeout(cfg.timeoutMs);
  let res: Response;
  try {
    res = await doFetch(`${cfg.baseUrl}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${cfg.apiKey}` },
      body: JSON.stringify({
        model: cfg.model,
        messages,
        thinking: { type: "disabled" },
        max_tokens: MAX_TOKENS,
        temperature: TEMPERATURE,
        stream: false,
      }),
      signal,
    });
  } catch (e) {
    throw new DeepSeekError(signal.aborted ? "timeout" : `network: ${(e as Error).message}`, false);
  }

  if (!res.ok) {
    await res.body?.cancel();
    throw new DeepSeekError(`http ${res.status}`, res.status === 429 || res.status >= 500, res.status);
  }

  let data: {
    model?: string;
    choices?: { message?: { content?: string | null } }[];
    usage?: { prompt_tokens?: number; completion_tokens?: number };
  };
  let text: string;
  try {
    text = await res.text();
  } catch (e) {
    // headers can arrive long before a non-streaming body, so the deadline may expire while reading it
    throw new DeepSeekError(signal.aborted ? "timeout" : `network: ${(e as Error).message}`, false, res.status);
  }
  try {
    data = JSON.parse(text);
  } catch {
    throw new DeepSeekError("invalid json", true, res.status);
  }
  const content = data.choices?.[0]?.message?.content?.trim() ?? "";
  if (!content) throw new DeepSeekError("empty reply", true, res.status);
  return {
    content: content.slice(0, 2000),
    model: data.model ?? cfg.model,
    tokensIn: data.usage?.prompt_tokens ?? null,
    tokensOut: data.usage?.completion_tokens ?? null,
  };
}

// One retry at most: each admitted message may cost two calls, which is what the daily cost cap assumes (§2.7).
export async function completeWithRetry(cfg: DeepSeekConfig, messages: ChatTurn[]): Promise<Completion> {
  try {
    return await chatCompletion(cfg, messages);
  } catch (e) {
    if (e instanceof DeepSeekError && e.retryable) return await chatCompletion(cfg, messages);
    throw e;
  }
}
