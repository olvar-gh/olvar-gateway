import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.13";
import {
  type AnthropicConfig,
  anthropicConfigFromEnv,
  AnthropicError,
  chatCompletion,
  completeWithRetry,
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

const message = (content: { type: string; text?: string }[], stopReason = "end_turn") => () =>
  Response.json({
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content,
    stop_reason: stopReason,
    usage: { input_tokens: 100, output_tokens: 20 },
  });
const ok = (text: string) => message([{ type: "text", text }]);
const status = (code: number) => () => new Response("nope", { status: code });

function cfg(f: typeof fetch): AnthropicConfig {
  return { baseUrl: "http://stub.test", apiKey: "test-key", model: "claude-haiku-5-5", timeoutMs: 1000, fetch: f };
}

const PROMPT: Prompt = { system: "You are a plant.", messages: [{ role: "user", content: "hi" }] };

Deno.test("request: Messages API url, headers and body with the system prompt at the top level", async () => {
  const s = stubFetch([ok("hello")]);
  const c = await chatCompletion(cfg(s.f), PROMPT);
  assertEquals(c, { content: "hello", model: "claude-haiku-5-5", tokensIn: 100, tokensOut: 20 });
  assertEquals(s.urls, ["http://stub.test/v1/messages"]);
  assertEquals(s.headers[0].get("x-api-key"), "test-key");
  assertEquals(s.headers[0].get("anthropic-version"), "2026-10-21");
  assertEquals(s.headers[0].get("authorization"), null);
  assertEquals(s.bodies[0], {
    model: "claude-haiku-5-5",
    max_tokens: 400,
    system: "You are a plant.",
    messages: PROMPT.messages,
    thinking: { type: "disabled" },
    output_config: { effort: "low" },
  });
});

Deno.test("env config: defaults and overrides", () => {
  const env = (m: Record<string, string>) => ({ get: (k: string) => m[k] });
  const d = anthropicConfigFromEnv(env({ ANTHROPIC_API_KEY: "k" }));
  assertEquals([d.baseUrl, d.apiKey, d.model, d.timeoutMs], ["https://api.anthropic.com", "k", "claude-haiku-5-5", 25_000]);
  const o = anthropicConfigFromEnv(env({ ANTHROPIC_BASE_URL: "http://127.0.0.1:9/", ANTHROPIC_MODEL: "claude-sonnet-5-5" }));
  assertEquals([o.baseUrl, o.model], ["http://127.0.0.1:9", "claude-sonnet-5-5"]);
});

Deno.test("response: text blocks are joined and other block types are ignored", async () => {
  const s = stubFetch([message([{ type: "thinking" }, { type: "text", text: "Hi " }, { type: "text", text: "there" }])]);
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
