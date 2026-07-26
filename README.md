# Backchannel

**A self-hosted Google Meet copilot whose brain is a persistent Jac graph.**

Built at JacHacks SF 2026 · Track: Agentic AI · also submitted for Best Use of Jac and Best JacHammer.

---

## The pitch

Otter, Fireflies and Zoom AI are someone else's cloud listening to your meeting. **Backchannel is
self-hosted end to end** — captions are scraped locally, reasoned about locally, and stored locally.

Mid-meeting, anyone says **"Hey Jac, …"**. A deterministic wake-phrase detector fires, a `by llm()`
intent router classifies QUESTION vs ACTION, and Backchannel either:

- **answers**, grounded in a pre-loaded document + the live transcript + prior sessions of this same
  recurring meeting, carrying a **typed source citation** (`DOC` / `TRANSCRIPT` / `PRIOR_MEETING` /
  `UNKNOWN`), spoken aloud; or
- **acts**, through a pluggable org-agent adapter — the shipped one files a real GitHub issue.

Three claims that stay true in every part of this repo:

1. **The trigger path makes zero LLM calls.** Wake detection is a lowercase substring scan. Nothing
   reaches a model until a human actually says the phrase.
2. **Every answer carries its evidence.** `GroundedAnswer.source` is an *enum*, not prose — so
   "I don't know" is a first-class typed outcome, not a hallucination waiting to happen.
3. **The meeting IS the graph. There is no database.** Kill the server mid-meeting, restart it, and
   ask "what did we decide earlier?" — the memory is still there, because every node is
   root-reachable and Jac persists it for free.

## Why this is a Jac project, not a Python project in disguise

**80% of this repo is Jac** (1,700 lines Jac / 423 lines Python — the Python is only the Playwright
browser driver, which has to be Python because Playwright is).

| Jac primitive | Where it earns its keep |
|---|---|
| **Object-Spatial Programming** | `IngestChunk` *walks* `root → MeetingSeries → Session` and upserts at the session. `AnswerQuestion` is spawned **on the Session node**, so assembling context (transcript, doc chunks, prior meetings) is graph traversal — not a query layer. |
| **Graph-native persistence** | No database, no ORM, no save calls. `MeetingSeries → Session → Utterance` is the storage engine. Verified across real server restarts. |
| **Meaning-Typed Programming** | Four `by llm()` functions whose *return types* do the work: `GroundedAnswer` (enum-typed citation), `RoutedIntent`, `SummaryUpdate` (enum verdict = the summary's stability contract), `SessionDistill`. Prompts live in `sem` strings. |
| **Single-language full stack** | The dashboard is `frontend.cl.jac` + `components/Cards.cl.jac`, compiled to React, calling the same walkers over `root spawn` — one language, one repo, no API client to hand-write. |

The grounding document loaded for the demo is **the judges' own MTP paper** (arXiv 2405.08965).
Backchannel answers questions about Meaning-Typed Programming, using Meaning-Typed Programming.

## Architecture

```
 Google Meet ──guest join──┐
                           │ headed Chromium + Playwright (ears/bot.py)
                           │ MutationObserver on the caption DOM
                           ▼
   replay.jac ───────► POST /walker/IngestChunk ───► Jac server (the brain)
   (scripted ears)         ONE inlet, three sources    │
                                                       │  graph: MeetingSeries → Session → Utterance
                                                       │                      → SessionSummary
                                                       │                      → Doc → DocChunk
                                                       │         Session → Answer / Action
                                                       │
                                                       ├─ wake detect (no LLM)
                                                       ├─ route_intent()      by llm()
                                                       ├─ answer_question()   by llm()
                                                       ├─ revise_summary()    by llm()
                                                       ├─ distill_session()   by llm()
                                                       │
   frontend.cl.jac ◄── root spawn Tick (every 2s) ─────┤
   live feed · summary · cited answer cards · TTS      ├──► OpenAI tts-1 → mp3
                                                       └──► GitHub REST → real issue
```

### Files

| File | Role |
|---|---|
| `backchannel/graph.sv.jac` | Node archetypes + get-or-create helpers. The whole data model. |
| `backchannel/ingest.sv.jac` | `IngestChunk` (the one inlet), `Tick` (client cursor), `LoadDoc`, wake detector |
| `backchannel/ai.sv.jac` | `by llm()` signatures, `sem` prompts, enums/objs, deterministic fallbacks |
| `backchannel/answer.sv.jac` | `AnswerQuestion`, `ExecuteAction`, `EndSession`, `Summarize`, summary cadence |
| `backchannel/adapters.sv.jac` | `dispatch_action` org-agent seam, GitHub REST, OpenAI TTS, local playback |
| `backchannel/frontend.cl.jac` | The dashboard, in Jac, compiled to React |
| `backchannel/replay.jac` | Scripted ears — drives the same HTTP inlet as the bot |
| `backchannel/ears/bot.py` | Playwright Meet capture bot (+ `locators.py`, the one file to hotfix) |

## Quick start

```bash
cd backchannel
cp .env.example .env          # add your OPENAI_API_KEY
./run.sh                      # http://localhost:8000
```

In a second terminal:

```bash
cd backchannel
jac run replay.jac            # scripted meeting streams into the graph
```

Watch the dashboard. Full demo script and the live-Meet path: **[DEMO.md](DEMO.md)**.

Backchannel degrades instead of failing: with no `OPENAI_API_KEY` it falls back to deterministic
keyword retrieval, and with no `GITHUB_PAT` the action adapter returns a dry-run receipt. Both paths
are honest on screen about what they are.

## Honest scope

- The org-agent integration is an **adapter and an architecture**, demonstrated with the GitHub REST
  API. There is no live internal-agent (Glean-style) integration in this repo and none is claimed.
- The Meet caption scraper depends on Google Meet's DOM, which is not a public API. Selectors live in
  `ears/locators.py` precisely because they will drift.
- The bot joins **muted, camera off**, and a human must click Admit. It cannot let itself in.

## License

MIT
