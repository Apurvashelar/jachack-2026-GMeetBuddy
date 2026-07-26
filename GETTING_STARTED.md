# Getting started — beginner guide

Assumes you know nothing beyond "I can open a terminal." Follow in order. Each step tells you
exactly what you should see, so you know whether it worked before moving on.

**Where to run these:** every command starts by getting into the project folder. If you're lost,
run this first and you're back on track:

```bash
cd ~/Downloads/jachack-2026-GMeetBuddy/backchannel
```

---

## Part 1 — Get an OpenAI API key (5 min, costs ~$0.50)

The app works without a key, but answers are dumb (it just keyword-matches the document). With a
key it actually reasons. You want the key.

1. Go to **https://platform.openai.com/signup** and sign in (or create an account).
2. **This is the step people miss:** you must add money before a key works. Go to
   **https://platform.openai.com/settings/organization/billing/overview** → **Add to credit balance**
   → add **$5**. That is far more than this demo needs (`gpt-4o-mini` costs fractions of a cent per
   question; the whole hackathon will run you well under $1).
3. Go to **https://platform.openai.com/api-keys** → **Create new secret key** → name it
   `backchannel` → **Create**.
4. **Copy it now.** It looks like `sk-proj-AbCd...` and is shown exactly once. If you lose it, just
   delete it and make a new one — no harm done.

> A key is a password. Don't paste it into Slack, a screenshot, or a git commit. The file we put it
> in (`.env`) is already gitignored, so it cannot be committed by accident.

## Part 2 — Put the key where the app can find it

In your terminal, **replace `sk-YOURREALKEY` with the key you just copied**, and run:

```bash
cd ~/Downloads/jachack-2026-GMeetBuddy/backchannel
printf 'OPENAI_API_KEY=sk-YOURREALKEY\nBC_MODEL=gpt-4o-mini\nORG_AGENT_KIND=github\n' > .env
```

Check it landed (this prints the key with the middle hidden, so it's safe on a shared screen):

```bash
sed 's/\(sk-....\).*/\1<hidden>/' .env
```

You should see:

```
OPENAI_API_KEY=sk-proj<hidden>
BC_MODEL=gpt-4o-mini
ORG_AGENT_KIND=github
```

If you see nothing at all, the `printf` didn't run — check you were in the `backchannel` folder.

## Part 3 — Start the app

```bash
cd ~/Downloads/jachack-2026-GMeetBuddy/backchannel
./run.sh
```

**What you should see** (first start takes 30–60 seconds — it's compiling the web dashboard):

```
loaded .env
OPENAI_API_KEY set (model: gpt-4o-mini)
...
  ➜  Local:   http://localhost:8000/
  Server ready
```

The line that matters is **`OPENAI_API_KEY set`**. If it says
`!! OPENAI_API_KEY unset: answers use keyword-retrieval fallback`, go back to Part 2.

**Leave this terminal running.** It's the server. Closing it stops the app.

Now open **http://localhost:8000** in your browser. You should see the Backchannel dashboard, dark
themed, with **● BRAIN CONNECTED** in green at the top right.

> If it says **BRAIN OFFLINE** in red: an old copy of the server is stuck holding the port. Press
> `Ctrl-C` in the terminal, then run `pkill -9 -f "jac start"`, then `./run.sh` again. This is the
> single most common problem — `run.sh` tries to prevent it, but if you started the server some
> other way it can still happen.

## Part 4 — Feed it a meeting and watch it work

Open a **second terminal window** (leave the server running in the first one):

```bash
cd ~/Downloads/jachack-2026-GMeetBuddy/backchannel
jac run replay.jac
```

This plays a scripted 28-line meeting about a research paper, one line every ~1.4 seconds, into the
app — exactly as if real people were talking in a Google Meet.

**Watch the browser.** Over about 40 seconds you should see, in order:

1. The **live transcript** fill up line by line on the left.
2. A line highlighted in blue when someone says *"Hey Jac, how much faster did developers complete
   tasks using MTP…"* — and your **laptop speaks the answer out loud**.
3. An **answer card** on the right with a blue **GROUNDED IN DOC** badge, a real answer (it should
   mention **3.2× faster** and **45% fewer lines of code**), and a grey italic quote from the paper.
4. A second answer with an amber **NOT IN CONTEXT** badge — someone asked about "TPU v5 pods", which
   isn't in the paper, and the app **admits it doesn't know instead of making something up**. This is
   the beat judges care about most.
5. An **ORG-AGENT ACTION** card saying `DRY-RUN` (it becomes a real GitHub issue in Part 6).

**This is your demo.** If all five happen, you're ready to present.

### The one-command health check

If you just want to confirm it's alive without watching:

```bash
curl -s -X POST localhost:8000/walker/Tick -H 'Content-Type: application/json' \
  -d '{"series":"Research Weekly Sync","after_seq":-1}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['data']['reports'][0]; print('captions:',d['total'],'answers:',len(d['answers']),'actions:',len(d['actions']))"
```

Expected after a replay: `captions: 28 answers: 3 actions: 1`

### Starting over

To wipe the meeting and start clean (useful between rehearsals):

```bash
# Ctrl-C the server first, then:
rm -rf .jac/data && ./run.sh
```

## Part 5 — The "no database" trick (your best 30 seconds on stage)

1. Run the replay so there's a meeting in memory.
2. Go to the server terminal and press **`Ctrl-C`**. The app is now dead.
3. Run `./run.sh` again. Wait for `Server ready`.
4. Refresh the browser.

**The entire meeting is still there** — transcript, answers, action receipts. There is no database
in this project. Jac persists the graph automatically because every piece of it hangs off `root`.
Say that out loud when you demo it.

## Part 6 — Optional: make the GitHub action real (10 min)

Right now the "file an issue" beat shows `DRY-RUN`. To make it file a real issue:

1. Go to **https://github.com/settings/personal-access-tokens/new** (Fine-grained tokens).
2. **Token name:** `backchannel`. **Expiration:** 7 days.
3. **Repository access:** *Only select repositories* → pick `jachack-2026-GMeetBuddy`.
4. **Permissions** → *Repository permissions* → find **Issues** → set to **Read and write**.
5. **Generate token**, copy it (starts with `github_pat_`).
6. Add it to your `.env` — replace the placeholders with your GitHub username and the token:

```bash
cd ~/Downloads/jachack-2026-GMeetBuddy/backchannel
printf 'GITHUB_PAT=github_pat_YOURTOKEN\nGITHUB_OWNER=YOUR-GITHUB-USERNAME\nGITHUB_REPO=jachack-2026-GMeetBuddy\n' >> .env
```

7. Restart the server (`Ctrl-C`, then `./run.sh`) and run the replay again. The action card should
   now say **CREATED** with a clickable link to a real issue in your repo.

> Note the `>>` in that command (append) versus the single `>` in Part 2 (overwrite). Using `>` here
> would erase your OpenAI key.

## Part 7 — Optional: the live Google Meet bot

This is theatre — the app works fully without it, and the replay is the reliable path. Only attempt
it if you have spare time.

```bash
pip install playwright requests
python -m playwright install chromium

cd ~/Downloads/jachack-2026-GMeetBuddy/backchannel
python ears/bot.py --meet-url https://meet.google.com/xxx-xxxx-xxx \
                   --series "Research Weekly Sync" \
                   --brain http://localhost:8000
```

A Chrome window opens and asks to join your Meet. **You must click Admit yourself** from your phone
or another device — the bot joins muted with its camera off and cannot let itself in.

**Two things that will bite you:**
- Create the Meet from a **personal Gmail**, not a work/Workspace account. Workspace meetings usually
  block anonymous guests, and the bot is an anonymous guest.
- Google Meet's page structure changes without notice. If captions never appear, the app is fine —
  the selectors are stale. Every one of them lives in `ears/locators.py` with instructions at the
  top. **Do not debug this during your demo.** Fall back to `jac run replay.jac` and say "the same
  inlet, fed by a scripted meeting" — which is literally true.

## Part 8 — Deploying to JacHammer

**Be honest with yourself about priorities:** the hackathon says hosting on jachammer.ai is
"highly encouraged" and there's a **Best JacHammer $400** award, so it's worth doing — but a working
local demo beats a broken hosted one every time. Get Parts 1–5 solid first.

**What I could verify:** the schedule, prizes, and the requirement itself, from the
[official hacker guide](https://jachacks.org/sf-guide).

**What I could not verify:** jachammer.ai requires a login and publishes no public documentation, so
I can't give you accurate click-by-click steps without guessing — and a wrong guess wastes your time.

**So do this instead, in order:**

1. **Ask an organizer or mentor at the venue.** This is genuinely the fastest path — it's their
   platform, there will be someone in the room who deploys to it daily, and they'll have you live in
   a few minutes. Show them this repo and say: *"Jac web-app, entry point is `backchannel/main.jac`,
   I need to set one environment secret called `OPENAI_API_KEY`."* That sentence is everything they
   need to know.
2. **What to expect:** platforms like this connect to a public GitHub repo. Your repo is already
   public and already committed, so you should mostly be picking the repo and setting the project
   root to `backchannel/`.
3. **The one setting you must not forget:** add **`OPENAI_API_KEY`** as an environment secret in
   their dashboard. Without it the hosted version silently runs the dumb fallback. Leave `SPEAK_LOCAL`
   unset — a server has no speakers, and the code already handles that.
4. **After deploying,** open the hosted URL and run the Part 4 health check against it (swap
   `localhost:8000` for your hosted address) to confirm it's really working.

**Fallback that's fully verified**, if JacHammer fights you — Jac has its own Kubernetes deploy built
in, and this is documented in the toolchain:

```bash
cd ~/Downloads/jachack-2026-GMeetBuddy/backchannel
jac start main.jac --scale --dry-run   # prints the plan, changes nothing — always run this first
jac start main.jac --scale             # actually deploys
jac scale status main.jac              # check health
```

This needs a Kubernetes cluster configured, so it's not a beginner path — mention it to a mentor
rather than attempting it cold.

**On demo day: present from `localhost` regardless.** Deploy so you can tick the judging box and
link it on Devpost; demo locally so conference wifi can't ruin your four minutes.

## Part 9 — Before you present

- [ ] Ran Part 4 start to finish and saw all five things happen
- [ ] Practised the Part 5 kill-and-restart trick
- [ ] Laptop volume **up** (the dashboard speaks answers aloud)
- [ ] Browser zoomed to ~110% so judges can read the cards
- [ ] GitHub tab open on your issues page (if you did Part 6)
- [ ] **Starred https://github.com/jaseci-labs/jac** — it's a submission requirement
- [ ] **Partial submission on Devpost by 5:50 PM** — do it early and rough; you can edit after
- [ ] Final submission before **7:15 PM**

The full 4-minute script, word for word, is in **[DEMO.md](DEMO.md) § 5**. Read it once before you
go up.
