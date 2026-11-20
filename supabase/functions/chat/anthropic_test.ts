import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1.0.13";
import {
  type AnthropicConfig,
  anthropicConfigFromEnv,
  AnthropicError,
  chatCompletion,
  completeWithRetry,
  parseRetryAfter,
  type Prompt,
} from "./anthropic.ts";

type Reply = () => Response | Promise<Response>;

function stubFetch(replies: Reply[]) {
  const bodies: Record<string, unknown>[] = [];
  const urls: string[] = [];
  const headers: Headers[] = [];
  const f: typeof fetch = async (input, init) => {
    urls.push(String(input));
    headers.push(new Headers(init?.headers));
    bodies.push(JSON.parse(String(init?.body)));
    const next = replies.shift();
    if (!next) throw new Error("unexpected extra call");
    return await next();
  };
  return { f, bodies, urls, headers };
}

const message = (content: { type: string; text?: string; thinking?: string }[], stopReason = "end_turn") => () =>
  Response.json({
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-sonnet-5-5",
    content,
    stop_reason: stopReason,
    usage: { input_tokens: 100, output_tokens: 20 },
  });
const ok = (text: string) => message([{ type: "text", text }]);
const status = (code: number, headers: Record<string, string> = {}) => () =>
  new Response("nope", { status: code, headers });

/** A fake clock: sleep() advances it instead of waiting. */
function clock() {
  let t = 1_000_000;
  const sleeps: number[] = [];
  return {
    now: () => t,
    sleep: (ms: number) => {
      sleeps.push(ms);
      t += ms;
      return Promise.resolve();
    },
    sleeps,
  };
}

function cfg(f: typeof fetch, extra: Partial<AnthropicConfig> = {}): AnthropicConfig {
  return {
    baseUrl: "http://stub.test",
    apiKey: "test-key",
    model: "claude-sonnet-5-5",
    timeoutMs: 1000,
    budgetMs: 60_000,
    fetch: f,
    ...extra,
  };
}

const PROMPT: Prompt = { system: "You are a plant.", messages: [{ role: "user", content: "hi" }] };

Deno.test("request: Messages API url, headers and body with the system prompt at the top level", async () => {
  const s = stubFetch([ok("hello")]);
  const c = await chatCompletion(cfg(s.f), PROMPT);
  assertEquals(c, { content: "hello", model: "claude-sonnet-5-5", tokensIn: 100, tokensOut: 20 });
  assertEquals(s.urls, ["http://stub.test/v1/messages"]);
  assertEquals(s.headers[0].get("x-api-key"), "test-key");
  assertEquals(s.headers[0].get("anthropic-version"), "2026-10-21");
  assertEquals(s.headers[0].get("authorization"), null);
  assertEquals(s.bodies[0], {
    model: "claude-sonnet-5-5",
    max_tokens: 4000,
    system: "You are a plant.",
    messages: PROMPT.messages,
    thinking: { type: "adaptive" },
    output_config: { effort: "medium" },
  });
});

// Sonnet 5.5 rejects thinking "disabled"; "between_tools" is Sonnet 5.5 only; Haiku 5.5 accepts adaptive at any
// effort. Adaptive + medium is the one setting valid for both, so the body must not depend on the model.
for (const model of ["claude-sonnet-5-5", "claude-haiku-5-5"]) {
  Deno.test(`request: ${model} gets adaptive thinking at medium effort and room for thinking plus the reply`, async () => {
    const s = stubFetch([ok("hello")]);
    await chatCompletion(cfg(s.f, { model }), PROMPT);
    const body = s.bodies[0] as Record<string, unknown>;
    assertEquals(body.model, model);
    assertEquals(body.thinking, { type: "adaptive" });
    assertEquals(body.output_config, { effort: "medium" });
    assert((body.max_tokens as number) >= 2000, "max_tokens leaves room for thinking");
    for (const k of ["temperature", "top_p", "top_k"]) assert(!(k in body), `${k} is not sent`);
  });
}

Deno.test("env config: defaults and overrides", () => {
  const env = (m: Record<string, string>) => ({ get: (k: string) => m[k] });
  const d = anthropicConfigFromEnv(env({ ANTHROPIC_API_KEY: "k" }));
  assertEquals(
    [d.baseUrl, d.apiKey, d.model, d.timeoutMs, d.budgetMs],
    ["https://api.anthropic.com", "k", "claude-sonnet-5-5", 45_000, 100_000],
  );
  const o = anthropicConfigFromEnv(env({
    ANTHROPIC_BASE_URL: "http://127.0.0.1:9/",
    ANTHROPIC_MODEL: "claude-haiku-5-5",
    ANTHROPIC_TIMEOUT_MS: "30000",
    ANTHROPIC_BUDGET_MS: "70000",
  }));
  assertEquals([o.baseUrl, o.model, o.timeoutMs, o.budgetMs], ["http://127.0.0.1:9", "claude-haiku-5-5", 30_000, 70_000]);
});

Deno.test("response: only text blocks reach the user, thinking blocks are dropped", async () => {
  const s = stubFetch([
    message([
      { type: "thinking", thinking: "The soil reading is low, so..." },
      { type: "text", text: "Hi " },
      { type: "text", text: "there" },
    ]),
  ]);
  assertEquals((await chatCompletion(cfg(s.f), PROMPT)).content, "Hi there");
});

Deno.test("response: a reply cut off at max_tokens is still used", async () => {
  const s = stubFetch([message([{ type: "text", text: "I am a bit thir" }], "max_tokens")]);
  assertEquals((await chatCompletion(cfg(s.f), PROMPT)).content, "I am a bit thir");
});

for (const [name, first] of [["429", status(429)], ["5xx", status(503)], ["529 overloaded", status(529)], [
  "empty reply",
  ok("  "),
]] as const) {
  Deno.test(`retry: ${name} is retried once and the retry can succeed`, async () => {
    const s = stubFetch([first, ok("second time lucky")]);
    assertEquals((await completeWithRetry(cfg(s.f), PROMPT)).content, "second time lucky");
    assertEquals(s.bodies.length, 2);
  });

  Deno.test(`retry: ${name} twice gives up after two calls`, async () => {
    const s = stubFetch([first, first]);
    await assertRejects(() => completeWithRetry(cfg(s.f), PROMPT), AnthropicError);
    assertEquals(s.bodies.length, 2);
  });
}

Deno.test("retry: a 400 is not retried", async () => {
  const s = stubFetch([status(400)]);
  const e = await assertRejects(() => completeWithRetry(cfg(s.f), PROMPT), AnthropicError);
  assertEquals([e.status, e.retryable, s.bodies.length], [400, false, 1]);
});

Deno.test("retry: a refusal is not retried", async () => {
  const s = stubFetch([message([], "refusal")]);
  const e = await assertRejects(() => completeWithRetry(cfg(s.f), PROMPT), AnthropicError);
  assertEquals([e.message, e.retryable, s.bodies.length], ["refusal", false, 1]);
});

Deno.test("timeout: aborts after timeoutMs and is not retried", async () => {
  const f: typeof fetch = (_input, init) =>
    new Promise((_resolve, reject) => {
      init!.signal!.addEventListener("abort", () => reject(init!.signal!.reason));
    });
  let calls = 0;
  const counting: typeof fetch = (i, init) => {
    calls++;
    return f(i, init);
  };
  const e = await assertRejects(
    () => completeWithRetry({ ...cfg(counting), timeoutMs: 20 }, PROMPT),
    AnthropicError,
  );
  assertEquals([e.message, calls], ["timeout", 1]);
});

Deno.test("missing API key fails without calling the Anthropic API", async () => {
  const s = stubFetch([]);
  await assertRejects(() => chatCompletion({ ...cfg(s.f), apiKey: "" }, PROMPT), AnthropicError, "ANTHROPIC_API_KEY");
  assertEquals(s.bodies.length, 0);
});

Deno.test("timeout: a deadline that expires while reading the body stays a non-retried timeout", async () => {
  let calls = 0;
  const f: typeof fetch = (_input, init) => {
    calls++;
    return Promise.resolve(
      new Response(
        new ReadableStream({
          start(controller) {
            controller.enqueue(new TextEncoder().encode(" "));
            init!.signal!.addEventListener("abort", () => controller.error(init!.signal!.reason), { once: true });
          },
        }),
        { headers: { "Content-Type": "application/json" } },
      ),
    );
  };
  const e = await assertRejects(() => completeWithRetry({ ...cfg(f), timeoutMs: 20 }, PROMPT), AnthropicError);
  assertEquals([e.message, e.retryable, calls], ["timeout", false, 1]);
});

Deno.test("retry: a malformed body is still retried as invalid json", async () => {
  const s = stubFetch([() => new Response("{not json", { status: 200 }), ok("fine")]);
  assertEquals((await completeWithRetry(cfg(s.f), PROMPT)).content, "fine");
  assertEquals(s.bodies.length, 2);
});

Deno.test("retry-after: a 429 waits the requested delay before the one retry", async () => {
  const c = clock();
  const s = stubFetch([status(429, { "retry-after": "3" }), ok("after waiting")]);
  assertEquals((await completeWithRetry(cfg(s.f, c), PROMPT)).content, "after waiting");
  assertEquals([c.sleeps, s.bodies.length], [[3000], 2]);
});

Deno.test("retry-after: a delay that does not fit the budget returns the error without a second call", async () => {
  const c = clock();
  const s = stubFetch([status(429, { "retry-after": "120" })]);
  const e = await assertRejects(() => completeWithRetry(cfg(s.f, c), PROMPT), AnthropicError);
  assertEquals([e.message, e.retryAfterMs, c.sleeps, s.bodies.length], ["http 429", 120_000, [], 1]);
});

Deno.test("retry-after: a delay that leaves too little time for the retry call is not waited for", async () => {
  const c = clock();
  // 60 s budget, 1 s per-call timeout: a 59.5 s wait leaves 0.5 s, less than one call needs.
  const s = stubFetch([status(529, { "retry-after": "59.5" })]);
  await assertRejects(() => completeWithRetry(cfg(s.f, c), PROMPT), AnthropicError, "http 529");
  assertEquals([c.sleeps, s.bodies.length], [[], 1]);
});

Deno.test("budget: the retry's timeout is cut to what is left of the budget", async () => {
  let t = 0;
  const timeouts: number[] = [];
  const realTimeout = AbortSignal.timeout;
  AbortSignal.timeout = (ms: number) => {
    timeouts.push(ms);
    return realTimeout.call(AbortSignal, ms);
  };
  const f: typeof fetch = () => {
    t += 40_000; // each call takes 40 s of the fake clock
    return Promise.resolve(new Response("busy", { status: 503 }));
  };
  try {
    const e = await assertRejects(
      () => completeWithRetry(cfg(f, { now: () => t, timeoutMs: 45_000, budgetMs: 70_000 }), PROMPT),
      AnthropicError,
    );
    // 70 s budget and the first call used 40 s: the 30 s left is enough for a retry, and the retry gets only that.
    assertEquals([e.message, timeouts], ["http 503", [45_000, 30_000]]);
  } finally {
    AbortSignal.timeout = realTimeout;
  }
});

Deno.test("parseRetryAfter: seconds, HTTP dates and junk", () => {
  const now = Date.parse("2026-11-20T00:00:00Z");
  assertEquals(parseRetryAfter("7", now), 7000);
  assertEquals(parseRetryAfter("0", now), 0);
  assertEquals(parseRetryAfter("Fri, 20 Nov 2026 00:00:05 GMT", now), 5000);
  assertEquals(parseRetryAfter("Thu, 19 Nov 2026 23:00:00 GMT", now), 0);
  assertEquals(parseRetryAfter(null, now), null);
  assertEquals(parseRetryAfter("soon", now), null);
});
