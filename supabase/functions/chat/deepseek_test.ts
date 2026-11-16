import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.13";
import { chatCompletion, completeWithRetry, type DeepSeekConfig, deepSeekConfigFromEnv, DeepSeekError } from "./deepseek.ts";

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

const ok = (content: string | null) => () =>
  Response.json({
    model: "deepseek-flash",
    choices: [{ message: { role: "assistant", content } }],
    usage: { prompt_tokens: 100, completion_tokens: 20 },
  });
const status = (code: number) => () => new Response("nope", { status: code });

function cfg(f: typeof fetch): DeepSeekConfig {
  return { baseUrl: "http://stub.test", apiKey: "test-key", model: "deepseek-flash", timeoutMs: 1000, fetch: f };
}

const MSGS = [{ role: "user" as const, content: "hi" }];

Deno.test("request body: model deepseek-flash, thinking disabled, limits, bearer key", async () => {
  const s = stubFetch([ok("hello")]);
  const c = await chatCompletion(cfg(s.f), MSGS);
  assertEquals(c, { content: "hello", model: "deepseek-flash", tokensIn: 100, tokensOut: 20 });
  assertEquals(s.urls, ["http://stub.test/chat/completions"]);
  assertEquals(s.headers[0].get("authorization"), "Bearer test-key");
  assertEquals(s.bodies[0], {
    model: "deepseek-flash",
    messages: MSGS,
    thinking: { type: "disabled" },
    max_tokens: 350,
    temperature: 0.7,
    stream: false,
  });
});

Deno.test("env config: defaults and overrides", () => {
  const env = (m: Record<string, string>) => ({ get: (k: string) => m[k] });
  const d = deepSeekConfigFromEnv(env({ DEEPSEEK_API_KEY: "k" }));
  assertEquals([d.baseUrl, d.model, d.timeoutMs], ["https://api.deepseek.com", "deepseek-flash", 25_000]);
  const o = deepSeekConfigFromEnv(env({ DEEPSEEK_BASE_URL: "http://127.0.0.1:9/", DEEPSEEK_MODEL: "deepseek-v4-pro" }));
  assertEquals([o.baseUrl, o.model], ["http://127.0.0.1:9", "deepseek-v4-pro"]);
});

for (const [name, first] of [["429", status(429)], ["5xx", status(503)], ["empty reply", ok("  ")]] as const) {
  Deno.test(`retry: ${name} is retried once and the retry can succeed`, async () => {
    const s = stubFetch([first, ok("second time lucky")]);
    assertEquals((await completeWithRetry(cfg(s.f), MSGS)).content, "second time lucky");
    assertEquals(s.bodies.length, 2);
  });

  Deno.test(`retry: ${name} twice gives up after two calls`, async () => {
    const s = stubFetch([first, first]);
    await assertRejects(() => completeWithRetry(cfg(s.f), MSGS), DeepSeekError);
    assertEquals(s.bodies.length, 2);
  });
}

Deno.test("retry: a 400 is not retried", async () => {
  const s = stubFetch([status(400)]);
  const e = await assertRejects(() => completeWithRetry(cfg(s.f), MSGS), DeepSeekError);
  assertEquals([e.status, e.retryable, s.bodies.length], [400, false, 1]);
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
    () => completeWithRetry({ ...cfg(counting), timeoutMs: 20 }, MSGS),
    DeepSeekError,
  );
  assertEquals([e.message, calls], ["timeout", 1]);
});

Deno.test("missing API key fails without calling DeepSeek", async () => {
  const s = stubFetch([]);
  await assertRejects(() => chatCompletion({ ...cfg(s.f), apiKey: "" }, MSGS), DeepSeekError, "DEEPSEEK_API_KEY");
  assertEquals(s.bodies.length, 0);
});
