import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.13";
import { anchoredHistory, type ChatRow, type PlantContext } from "./context.ts";
import type { ChatTurn } from "./anthropic.ts";
import { AdmitError, createHandler, type NewReply, type Store, withErrorBoundary } from "./handler.ts";

const OWNER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const PLANT = "aaaaaaaa-0000-4000-8000-000000000001";
const READING_AT = "2026-11-16T05:04:00.000Z";

class MemoryStore implements Store {
  rows: ChatRow[] = [];
  private nextId = 1;
  limitedFor: number | null = null;

  canSeePlant(jwt: string, plantId: string) {
    return Promise.resolve(jwt === `jwt-${OWNER}` && plantId === PLANT);
  }

  admit(ownerId: string, plantId: string, content: string) {
    if (ownerId !== OWNER || plantId !== PLANT) return Promise.reject(new AdmitError("not_found"));
    if (this.limitedFor !== null) return Promise.reject(new AdmitError("rate_limited", this.limitedFor));
    const row = this.make({ plant_id: plantId, role: "user", content, reply_to: null });
    return Promise.resolve(row);
  }

  timezone = "UTC";

  loadContext(): Promise<Omit<PlantContext, "now">> {
    return Promise.resolve({
      nickname: "Lily",
      location: null,
      timezone: this.timezone,
      commonName: "Peace lily",
      scientificName: "Spathiphyllum wallisii",
      careNotes: "Keep moist.",
      thresholds: {},
      status: {
        overall: "great",
        overall_label: "Feeling great",
        summary: "All good, I'm feeling great",
        temperature_status: "ok",
        temperature_label: "Just right",
        humidity_status: "ok",
        humidity_label: "Just right",
        light_status: "ok",
        light_label: "Just right",
        soil_status: "ok",
        soil_label: "Just right",
        soil_calibrated: true,
        device_status: "online",
        latest_reading_at: READING_AT,
        issues: [],
      },
      latest: { recorded_at: READING_AT, temperature_c: 23, humidity_pct: 50, lux: 1500, soil_pct: 60 },
      hourly: [],
      daily: [],
    });
  }

  loadHistory(plantId: string) {
    return Promise.resolve(this.rows.filter((r) => r.plant_id === plantId).map((r) => ({ ...r })));
  }

  insertReply(r: NewReply) {
    if (this.rows.some((x) => x.reply_to === r.reply_to)) throw new Error("reply_to must be unique");
    return Promise.resolve(this.make(r));
  }

  private make(r: Partial<ChatRow> & Pick<ChatRow, "plant_id" | "role" | "content" | "reply_to">): ChatRow {
    const row: ChatRow = {
      based_on_reading_at: null,
      model: null,
      tokens_in: null,
      tokens_out: null,
      error: null,
      ...r,
      id: this.nextId++,
      created_at: new Date().toISOString(),
    };
    this.rows.push(row);
    return { ...row };
  }
}

type StubReply = (body: { system: string; messages: ChatTurn[] }) => Response | Promise<Response>;

/** A local HTTP server standing in for api.anthropic.com, reached through ANTHROPIC_BASE_URL. */
async function withStub(fn: (s: { url: string; bodies: Record<string, unknown>[]; replies: StubReply[] }) => Promise<void>) {
  const bodies: Record<string, unknown>[] = [];
  const replies: StubReply[] = [];
  const ac = new AbortController();
  const server = Deno.serve({ port: 0, hostname: "127.0.0.1", signal: ac.signal, onListen: () => {} }, async (req) => {
    const body = await req.json();
    bodies.push(body);
    const next = replies.shift();
    return next ? await next(body) : new Response("no stub reply queued", { status: 500 });
  });
  try {
    await fn({ url: `http://127.0.0.1:${server.addr.port}`, bodies, replies });
  } finally {
    ac.abort();
    await server.finished;
  }
}

const answer = (content: string): StubReply => () =>
  Response.json({
    type: "message",
    role: "assistant",
    model: "claude-sonnet-5-5",
    content: [{ type: "text", text: content }],
    stop_reason: "end_turn",
    usage: { input_tokens: 1200, output_tokens: 42 },
  });

function setup(baseUrl: string, timeoutMs = 2000) {
  const store = new MemoryStore();
  const logs: Record<string, unknown>[] = [];
  const handler = withErrorBoundary(createHandler({
    store,
    verifyUser: (jwt) => Promise.resolve(jwt.startsWith("jwt-") ? jwt.slice(4) : null),
    anthropic: { baseUrl, apiKey: "test-key", model: "claude-sonnet-5-5", timeoutMs },
    now: () => new Date("2026-11-16T05:05:00Z"),
    log: (e) => logs.push(e),
  }));
  const post = (body: unknown, user = OWNER) =>
    handler(
      new Request("http://localhost/functions/v1/chat", {
        method: "POST",
        headers: { Authorization: `Bearer jwt-${user}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
      }),
    );
  return { store, handler, post, logs };
}

function assertAlternatingPrompt(turns: ChatTurn[]) {
  turns.forEach((t, i) => assertEquals(t.role, i % 2 === 0 ? "user" : "assistant"));
  assertEquals(turns.at(-1)!.role, "user");
}

Deno.test("success: stores both rows and returns the plant reply", async () => {
  await withStub(async (s) => {
    s.replies.push(answer("I'm feeling lovely today!"));
    const { store, post } = setup(s.url);
    const res = await post({ plant_id: PLANT, message: "  How are you?  " });
    assertEquals(res.status, 200);
    const { reply } = await res.json();
    assertEquals(store.rows.length, 2);
    const [q] = store.rows;
    assertEquals([q.role, q.content], ["user", "How are you?"]);
    assertEquals(reply.role, "plant");
    assertEquals(reply.content, "I'm feeling lovely today!");
    assertEquals(reply.reply_to, q.id);
    assertEquals(reply.based_on_reading_at, READING_AT);
    assertEquals([reply.model, reply.tokens_in, reply.tokens_out, reply.error], ["claude-sonnet-5-5", 1200, 42, null]);

    const body = s.bodies[0] as { model: string; thinking: { type: string }; system: string; messages: ChatTurn[] };
    assertEquals(body.model, "claude-sonnet-5-5");
    assertEquals(body.thinking, { type: "adaptive" });
    assertStringIncludes(body.system, "You are Lily, a peace lily");
    assertStringIncludes(body.system, "same language as the person's latest message");
    assertStringIncludes(body.system, "LOCAL TIME:");
    assert(body.messages.every((m) => m.role === "user" || m.role === "assistant"), "no system turns in messages");
    assertEquals(body.messages, [{ role: "user", content: "How are you?" }]);
  });
});

const failures: [string, StubReply[], string, number?][] = [
  ["empty reply twice", [answer(""), answer("")], "empty reply"],
  ["429 twice", [() => new Response("busy", { status: 429 }), () => new Response("busy", { status: 429 })], "http 429"],
  ["5xx twice", [() => new Response("oops", { status: 502 }), () => new Response("oops", { status: 502 })], "http 502"],
  ["timeout", [() => new Promise((r) => setTimeout(() => r(new Response("late")), 300))], "timeout", 50],
];

for (const [name, replies, error, timeoutMs] of failures) {
  Deno.test(`fallback: ${name} stores a deterministic plant row with error set`, async () => {
    await withStub(async (s) => {
      s.replies.push(...replies);
      const { store, post, logs } = setup(s.url, timeoutMs);
      const res = await post({ plant_id: PLANT, message: "hi" });
      assertEquals(res.status, 200);
      const { reply } = await res.json();
      assertEquals(store.rows.length, 2);
      assertEquals(reply.error, error);
      assertEquals(reply.reply_to, store.rows[0].id);
      assertEquals(reply.based_on_reading_at, READING_AT);
      assertEquals(reply.model, null);
      assertStringIncludes(reply.content, "All good, I'm feeling great");
      assertEquals(s.bodies.length, replies.length);
      assertEquals(logs[0].event, "anthropic_failed");
    });
  });
}

Deno.test("retry: a 429 with Retry-After is retried once after the delay and the answer is stored", async () => {
  await withStub(async (s) => {
    s.replies.push(() => new Response("slow down", { status: 429, headers: { "retry-after": "0" } }), answer("Hi again."));
    const { post } = setup(s.url);
    const { reply } = await (await post({ plant_id: PLANT, message: "hi" })).json();
    assertEquals([reply.content, reply.error], ["Hi again.", null]);
    assertEquals(s.bodies.length, 2);
  });
});

Deno.test("retry: a 429 whose Retry-After exceeds the budget stores the fallback after one call", async () => {
  await withStub(async (s) => {
    s.replies.push(() => new Response("slow down", { status: 429, headers: { "retry-after": "3600" } }));
    const { post } = setup(s.url);
    const res = await post({ plant_id: PLANT, message: "hi" });
    assertEquals(res.status, 200);
    const { reply } = await res.json();
    assertEquals([reply.error, reply.model, s.bodies.length], ["http 429", null, 1]);
  });
});

Deno.test("retry: one empty reply then success stores the second answer", async () => {
  await withStub(async (s) => {
    s.replies.push(answer(""), answer("Better now."));
    const { post } = setup(s.url);
    const { reply } = await (await post({ plant_id: PLANT, message: "hi" })).json();
    assertEquals([reply.content, reply.error], ["Better now.", null]);
    assertEquals(s.bodies.length, 2);
  });
});

Deno.test("overlapping requests: each prompt is anchored to its own admitted message", async () => {
  await withStub(async (s) => {
    const { store, post } = setup(s.url);

    s.replies.push(answer("Hello there!"));
    await post({ plant_id: PLANT, message: "hello" });

    let releaseA!: () => void;
    const aWaiting = new Promise<void>((r) => (releaseA = r));
    let aArrived!: () => void;
    const aCalled = new Promise<void>((r) => (aArrived = r));
    s.replies.push(async () => {
      aArrived();
      await aWaiting;
      return answer("I'm great, thanks!")({ system: "", messages: [] });
    });
    s.replies.push(answer("아직 괜찮아요!"));

    const resA = post({ plant_id: PLANT, message: "How are you?" });
    await aCalled;
    const resB = await post({ plant_id: PLANT, message: "물 줘야 해?" });
    releaseA();
    const replyA = (await (await resA).json()).reply;
    const replyB = (await resB.json()).reply;

    const [, promptA, promptB] = s.bodies.map((b) => (b as { messages: ChatTurn[] }).messages);
    assertEquals(promptA.map((m) => m.content), ["hello", "Hello there!", "How are you?"]);
    assertEquals(promptB.map((m) => m.content), ["hello", "Hello there!", "물 줘야 해?"]);
    assert(!promptB.some((m) => m.content === "How are you?"), "B excludes A's unanswered question");
    assertAlternatingPrompt(promptA);
    assertAlternatingPrompt(promptB);

    const q = (content: string) => store.rows.find((r) => r.role === "user" && r.content === content)!;
    assertEquals(replyA.reply_to, q("How are you?").id);
    assertEquals(replyB.reply_to, q("물 줘야 해?").id);
    assertEquals(replyB.content, "아직 괜찮아요!");

    s.replies.push(answer("Sure."));
    await post({ plant_id: PLANT, message: "next" });
    const promptC = (s.bodies[3] as { messages: ChatTurn[] }).messages;
    assertEquals(
      promptC.map((m) => m.content),
      ["hello", "Hello there!", "How are you?", "I'm great, thanks!", "물 줘야 해?", "아직 괜찮아요!", "next"],
    );
    assertAlternatingPrompt(promptC);
    assertEquals(promptC, anchoredHistory(store.rows, store.rows.find((r) => r.content === "next")!));
  });
});

Deno.test("ownership: a non-owner gets 404 and nothing is stored or sent", async () => {
  await withStub(async (s) => {
    const { store, post } = setup(s.url);
    const res = await post({ plant_id: PLANT, message: "hi" }, OTHER);
    assertEquals(res.status, 404);
    assertEquals((await res.json()).error, "plant_not_found");
    assertEquals([store.rows.length, s.bodies.length], [0, 0]);
  });
});

Deno.test("rate limit: 429 with retry_after and no Anthropic API call", async () => {
  await withStub(async (s) => {
    const { store, post } = setup(s.url);
    store.limitedFor = 37;
    const res = await post({ plant_id: PLANT, message: "hi" });
    assertEquals(res.status, 429);
    assertEquals(res.headers.get("retry-after"), "37");
    assertEquals(await res.json(), { error: "rate_limited", retry_after: 37 });
    assertEquals(s.bodies.length, 0);
  });
});

Deno.test("input validation and auth", async () => {
  await withStub(async (s) => {
    const { store, post, handler } = setup(s.url);
    assertEquals((await post({ plant_id: PLANT, message: "   " })).status, 400);
    assertEquals((await post({ plant_id: PLANT, message: "x".repeat(1001) })).status, 400);
    assertEquals((await post({ plant_id: PLANT, message: 5 })).status, 400);
    assertEquals((await post({ plant_id: "not-a-uuid", message: "hi" })).status, 400);
    assertEquals((await post({ message: "hi" })).status, 400);
    const raw = (init: RequestInit) => handler(new Request("http://localhost/functions/v1/chat", init));
    assertEquals((await raw({ method: "POST", body: "{}" })).status, 401);
    assertEquals((await raw({ method: "POST", headers: { Authorization: "Bearer bad" }, body: "{}" })).status, 401);
    assertEquals(
      (await raw({ method: "POST", headers: { Authorization: `Bearer jwt-${OWNER}` }, body: "{not json" })).status,
      400,
    );
    assertEquals((await raw({ method: "GET", headers: { Authorization: `Bearer jwt-${OWNER}` } })).status, 405);
    assertEquals((await raw({ method: "OPTIONS" })).status, 204);
    assertEquals(store.rows.length, 0);

    s.replies.push(answer("ok"));
    assertEquals((await post({ plant_id: PLANT, message: "x".repeat(1000) })).status, 200);
  });
});

Deno.test("store failure: unexpected errors become a 500 without leaking details", async () => {
  await withStub(async (s) => {
    const { store, post } = setup(s.url);
    store.loadContext = () => Promise.reject(new Error("db down"));
    const res = await post({ plant_id: PLANT, message: "hi" });
    assertEquals([res.status, await res.json()], [500, { error: "internal" }]);
  });
});

Deno.test("timezone: a database-valid posix/ zone still gets a reply instead of a 500 after admission", async () => {
  await withStub(async (s) => {
    s.replies.push(answer("Annyeong!"));
    const { store, post } = setup(s.url);
    store.timezone = "posix/Asia/Seoul";
    const res = await post({ plant_id: PLANT, message: "hi" });
    assertEquals(res.status, 200);
    assertEquals((await res.json()).reply.content, "Annyeong!");
    assertEquals(store.rows.map((r) => r.role), ["user", "plant"]);
    assertStringIncludes((s.bodies[0] as { system: string }).system, "(Asia/Seoul)");
  });
});
