# Slack setup — step by step

Two ways to talk to Backchannel from Slack. **Start with Option A** — it works in
3 minutes with no public URL. Option B gives you the literal `/backchannel` slash
command but needs one more moving part.

---

## Option A — mention the bot (3 min, no public URL)

Backchannel polls Slack with your token, so nothing needs to reach your laptop
from the internet. Everything below works identically to the slash command; you
type `@Backchannel …` instead of `/backchannel …`.

**1. Create the app**
1. Go to **https://api.slack.com/apps** → **Create New App** → **From a manifest**
2. Pick your workspace
3. Paste the contents of **`slack_manifest.yaml`** (in this repo), then **Create**

**2. Install it**
1. Left sidebar → **Install App** → **Install to Workspace** → **Allow**
2. Copy the **Bot User OAuth Token** — it starts `xoxb-`

**3. Give it to Backchannel**
```bash
cd ~/Downloads/jachack-2026-GMeetBuddy
printf 'SLACK_BOT_TOKEN=xoxb-PASTE-YOURS-HERE\n' >> .env
```
Restart: `Ctrl-C` in the server terminal, then `./run.sh`.

**4. Watch it appear.** Open the dashboard once. Within ~10 seconds Backchannel
creates **`#bc-research-weekly-sync`** in your Slack and posts a welcome message.

**5. Use it** — in that channel:

| You type | What happens |
|---|---|
| `@Backchannel what did we decide about the classifier?` | Grounded answer with its source |
| `@Backchannel transcript` | The live transcript tail |
| `@Backchannel summarize` | Forces a summary revision and posts it |
| *(drag a PDF or .md into the channel)* | Becomes searchable knowledge automatically |

Replies take up to ~8 seconds — that's the poll interval, not the model.

---

## Option B — the real `/backchannel` slash command

**Why this needs an extra piece, honestly:** Slack sends slash commands as
`application/x-www-form-urlencoded`. This build of Jac binds **JSON** request
bodies onto walker fields and returns `422` for form bodies. So `ears/slack_shim.py`
(~60 lines, Python stdlib only) accepts Slack's form POST, checks the signature,
and forwards it as JSON to the brain's `/slack/command` endpoint.

**1. Expose a public URL.** You already have one if you deployed to JacHammer —
otherwise use a tunnel:
```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:3030
# copy the https://....trycloudflare.com URL it prints
```

**2. Run the shim** (new terminal, leave it running):
```bash
cd ~/Downloads/jachack-2026-GMeetBuddy
set -a; . ./.env; set +a
python3 ears/slack_shim.py --brain http://localhost:8000 --port 3030
```

**3. Register the command**
1. https://api.slack.com/apps → your app → **Slash Commands** → **Create New Command**
2. **Command:** `/backchannel`
3. **Request URL:** your public URL from step 1 (e.g. `https://xyz.trycloudflare.com`)
4. **Short description:** `Ask your meeting anything`
5. **Usage hint:** `<Project> ask <question>`
6. **Save**, then **reinstall the app** when Slack prompts

**4. Add the signing secret.** App → **Basic Information** → **Signing Secret** → Show:
```bash
printf 'SLACK_SIGNING_SECRET=PASTE-SIGNING-SECRET\n' >> .env
```
Restart both the shim and the server. Without this the endpoint is public and
unauthenticated — fine for a demo on localhost, not fine on a deployed URL.

**5. Try it** from any channel:
```
/backchannel help
/backchannel projects
/backchannel start https://meet.google.com/abc-defg-hij Payments Revamp
/backchannel Payments Revamp ask what did we decide about retries?
/backchannel Payments Revamp transcripts
/backchannel Payments Revamp summarized transcripts
```

---

## The two kinds of knowledge

This distinction is the point — use the right one and answers get much better.

| | **Searchable (RAG)** | **Pinned (direct)** |
|---|---|---|
| Command | `/backchannel <Project> load <url>` | `/backchannel <Project> pin <text or url>` |
| Dashboard | *Knowledge → searchable* | *Knowledge → always in context* |
| Folder | `meetings/<project>/docs/` | `meetings/<project>/pinned/` |
| How it reaches the model | Chunked; only relevant pieces sent | Sent **verbatim, every single answer** |
| Use for | Papers, wikis, specs, long PDFs | Agenda, glossary, team context, "ACH means…" |

Pinned material is never filtered out by a bad keyword match — that's exactly
why it exists. Keep it short (a paragraph or two); it costs tokens on every
question.

Both survive restarts, and `context.md` in each project folder carries decisions
into the next meeting automatically.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| No channel appears | Token missing or wrong. Check `./run.sh` prints no Slack errors, and that the token starts `xoxb-` (not `xoxp-`). |
| `not_in_channel` | Invite the bot: type `/invite @Backchannel` in the channel. |
| Slash command says "operation timed out" | The shim isn't running, or the Request URL is wrong/expired (tunnel URLs change on restart). |
| `/backchannel` returns 422 | You pointed Slack straight at the Jac server. Point it at the **shim**. |
| Bot can't join a Meet from Slack | Expected on a hosted deploy — the bot needs a display. Run Backchannel locally for the meeting bot. |
