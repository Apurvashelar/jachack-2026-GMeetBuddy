# Backchannel — run it, demo it, ship it

Everything below was executed on this machine. Times are from the
[JacHacks SF hacker guide](https://jachacks.org/sf-guide).

---

## 0. Deadlines (today)

| Time | What |
|---|---|
| **5:50 PM** | Partial submission checkpoint — **submit something, non-negotiable** |
| **7:15 PM** | Final submissions close (hard) |
| **7:30–8:15 PM** | Live demos, **4 minutes per team**, in parallel groups |
| 8:45–9:15 PM | Second-round demos (top teams) |
| 9:30 PM | Awards |

Required for submission: project name + description · **public GitHub repo, ≥40% Jac** (this repo is
**80% Jac**) · demo video · track selection · **star `jaseci-labs/jac`** · hosting on jachammer.ai
(highly encouraged, and explicitly part of judging).

Judges prefer **a working demo over a presentation**. One team member must demo in person.

---

## 1. One-time setup (5 minutes)

```bash
cd backchannel
cp .env.example .env
```

Edit `.env` and set at minimum:

```
OPENAI_API_KEY=sk-...
```

For the "files a real GitHub issue" beat, also set (use a **personal fine-grained PAT** scoped to
Issues:write on your public hackathon repo only):

```
GITHUB_PAT=github_pat_...
GITHUB_OWNER=your-username
GITHUB_REPO=jachack-2026-GMeetBuddy
```

Then install the browser bot's deps (only needed for the live-Meet path):

```bash
pip install playwright requests && python -m playwright install chromium
```

## 2. Start the brain

```bash
./run.sh              # dev server + dashboard on http://localhost:8000
./run.sh --api        # API only, faster boot, no dashboard
```

`run.sh` loads `.env`, prints whether the LLM is live, and **kills any stale `jac start` first** —
that matters, because a stale process holding :8000 makes the new server silently grab :8001 while
the dashboard's proxy still points at :8000, and every call then looks broken.

Wait for `Local: http://localhost:8000/`. First boot bundles the client and takes ~30–60s.

**Verify it's healthy:**

```bash
curl -s -X POST localhost:8000/walker/Tick \
  -H 'Content-Type: application/json' \
  -d '{"series":"Research Weekly Sync","after_seq":-1}' | python3 -m json.tool | head -20
```

## 3. Drive it with the scripted meeting

```bash
cd backchannel
jac run replay.jac                 # natural pace (~1.4s/line, ~40s total)
BC_DELAY=0.3 jac run replay.jac    # fast, for rehearsal
```

This loads the MTP paper as the grounding doc, then streams 28 scripted lines through
`POST /walker/IngestChunk` — **the exact same inlet the live bot uses**.

Three wake phrases fire in the script: a question answerable from the paper, a question deliberately
*not* in the paper (shows the honest `UNKNOWN`), and a "file an issue" action.

## 4. The live Meet path (the theatre)

1. Create a Meet from a **personal Gmail** — Workspace-hosted meetings often block anonymous guests.
   Verify a guest can join *before* you rely on it.
2. Start the brain, then:

```bash
python ears/bot.py --meet-url https://meet.google.com/xxx-xxxx-xxx \
                   --series "Research Weekly Sync" \
                   --brain http://localhost:8000
```

3. A headed Chromium window opens and asks to join. **You click Admit on your own device** — the bot
   cannot admit itself.
4. The bot turns captions on and installs the caption observer. Speak; watch the dashboard.

> **If captions don't appear:** open devtools on the Meet tab, inspect a caption line, walk up to its
> stable container, and put that selector at the **front** of `CAPTION_REGIONS` in
> `ears/locators.py`. That file exists so this is a 30-second fix, not a rewrite. Meet's DOM is not a
> public API and it does drift.

**Fallback if the bot fights you:** run `replay.jac` instead and narrate it as "the same inlet, fed
by a scripted meeting." Nothing else changes — the brain cannot tell the difference. Do not burn
demo time debugging selectors.

---

## 5. The 4-minute demo script

Rehearse this once. Have **two terminals + the dashboard + a GitHub tab** open before you start.

| Time | Beat | What you say |
|---|---|---|
| **0:00–0:30** | Dashboard on screen, bot visibly joining the Meet | "Otter and Zoom AI are someone else's cloud listening to your meeting. Backchannel is self-hosted end to end — and its brain is a Jac graph, not a database." |
| **0:30–1:15** | Speak (or start replay). Feed scrolls, summary appears | "Captions stream into one walker. This is the whole storage engine: root → series → session → utterance. No database, no ORM." |
| **1:15–2:00** | Say **"Hey Jac, how much faster did developers complete tasks using MTP?"** → answer card + spoken aloud | "The trigger is a substring scan — zero model calls until someone actually says it. And the answer arrives with a **typed** citation: `source` is an enum, so provenance is a type the compiler knows about." **Point at the GROUNDED IN DOC badge.** |
| **2:00–2:25** | Say **"Hey Jac, what does the paper say about training throughput on TPU v5 pods?"** → `NOT IN CONTEXT` | "It's not in the paper, so it says so. `UNKNOWN` is a first-class enum value, not a hallucination." |
| **2:25–3:00** | Say **"Hey Jac, file an issue to reproduce the MTP benchmark."** → switch to GitHub tab, real issue | "Same wake phrase, different intent — a `by llm()` router split those. This adapter is the seam where an internal agent plugs in. Ask *and* act, from inside the meeting." |
| **3:00–3:40** | **Ctrl-C the server. Restart it.** Ask "Hey Jac, what did we decide earlier?" | "I just killed the brain. No database was involved — every node is root-reachable, so Jac persisted the meeting for free. It still remembers what we decided." |
| **3:40–4:00** | Close on `/graph` visualizer + "80% Jac" | "One language: the graph, the walkers, the LLM calls, and this dashboard are all Jac. The paper it just answered questions about is the MTP paper — it used Meaning-Typed Programming to answer questions about Meaning-Typed Programming." |

**The kicker beat** is the restart. Don't skip it — it's the thing no other team will show.

Free demo candy if you have spare seconds: **`http://localhost:8000/graph`** is a live graph
visualizer, built in. Swagger is at `/docs`.

### Rehearsal checklist

- [ ] `.env` has a working `OPENAI_API_KEY` (dashboard answers should be *specific*, not generic)
- [ ] GitHub tab already logged in and pointed at the issues page
- [ ] Ran `replay.jac` once end-to-end and watched every card render
- [ ] Practised the kill-and-restart beat — know exactly which terminal to Ctrl-C
- [ ] Laptop volume up (the answer is spoken by the dashboard)
- [ ] Zoom the browser to ~110% so judges can read the cards

---

## 6. Deploying (judging explicitly rewards this)

Hosting on **jachammer.ai is highly encouraged** and there's a **Best JacHammer $400** award.
Take the JacHammer path first — it's the one being judged.

**JacHammer:** sign in at [jachammer.ai](https://jachammer.ai), connect this public GitHub repo,
point it at `backchannel/` as the project root (`main.jac` is the entry), and add `OPENAI_API_KEY`
(plus the GitHub vars if you want live actions) as environment secrets in its dashboard. `SPEAK_LOCAL`
must stay unset/`0` — a hosted server has no audio device, and the code already no-ops it.

**Self-hosted Kubernetes** (the toolchain's own path, if you'd rather show that):

```bash
jac start main.jac --scale --dry-run   # lint + print the plan, applies nothing
jac start main.jac --scale             # deploy
jac scale status main.jac
```

with secrets declared in `jac.toml`:

```toml
[scale.secrets]
OPENAI_API_KEY = "${OPENAI_API_KEY}"
```

⚠ Whatever you deploy, **demo against localhost anyway** unless the hosted version is rock solid.
Conference wifi has ended more demos than bad code. Deploy for the judging checkbox; demo locally.

---

## 7. Submission checklist

- [ ] **Partial submit by 5:50 PM** — do this even if rough
- [ ] Public GitHub repo, all commits inside hacking hours (10:45 AM–7:15 PM); commits are verified
- [ ] ≥40% Jac — this repo is **80%** (`1,700` Jac / `423` Python)
- [ ] Demo video recorded (record the 4-minute script above; keep it under 3 min if the form asks)
- [ ] Deployed to jachammer.ai
- [ ] **Star [`jaseci-labs/jac`](https://github.com/jaseci-labs/jac)**
- [ ] Track: **Agentic AI**; special awards: **Best Use of Jac**, **Best JacHammer**
- [ ] Devpost description names the primitives explicitly: Object-Spatial Programming (walkers/nodes/
      edges), graph-native persistence, Meaning-Typed Programming (`by llm()` + `sem` + typed returns),
      single-language full stack (`.cl.jac` frontend)
- [ ] Final submit before **7:15 PM**

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Dashboard says **BRAIN OFFLINE**, or data appears via curl but not the UI | A stale `jac start` holds :8000 and the new server grabbed :8001. `pkill -9 -f "jac start"`, then `./run.sh`. This is the #1 gotcha. |
| `405` on an endpoint | Its name is missing from `main.jac`'s import list. Add it. |
| `500 "Invalid anchor id"` | Node schema changed under persisted data → `rm -rf .jac/data/` and restart. |
| Feed frozen for ~60s | Something used an `sv import` reader call instead of `root spawn Tick(...)` — reader responses are cached 60s. |
| Answers are vague/generic | `OPENAI_API_KEY` isn't reaching the server, OR the OpenAI account has **no billing credit** (server log shows `429 ... exceeded your current quota` — add ~$5 at platform.openai.com billing). Check `./run.sh` output. |
| Server log: `'litellm' is required` | Run `./run.sh` — it self-installs litellm into `.jac/venv` (binary-only; a plain `jac install litellm` fails on Python 3.14). |
| Action card says `dry-run` | `GITHUB_PAT` / `GITHUB_OWNER` / `GITHUB_REPO` unset. Expected without them. |
| Editing `.jac` files mid-demo breaks the graph | HMR reloads archetypes under persisted data. **Don't edit files during the demo.** |
| Bot never gets into the Meet | Nobody clicked Admit, or the meeting is Workspace-hosted and blocks guests. Use a personal Gmail meeting. |
