#!/usr/bin/env python3
"""Backchannel ears - a Playwright bot that joins a Google Meet and streams
closed captions into the Jac brain.

    python ears/bot.py --meet-url https://meet.google.com/abc-defg-hij \
                       --series "Research Weekly Sync" \
                       --brain http://localhost:8000

Design notes:

* Headed Chromium, not headless. Headless trips Meet's bot detection, and a
  visible browser window is also the demo: the audience watches it join.
* Captions are scraped from the DOM via an injected MutationObserver rather
  than pulled from an API, because there is no public caption API. Every
  selector lives in `locators.py`.
* Each caption block gets a stable synthetic `caption_id` and a `version` that
  increments on every text change. The brain upserts on that pair, so the bot
  can redeliver an evolving caption as often as it likes - redelivery is free
  and no line is ever double-counted.
* The bot joins muted with its camera off, and a HUMAN must click Admit. It
  cannot let itself into a meeting.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from queue import Empty, Queue

try:
    import requests
except ImportError:
    sys.exit("missing dependency: pip install requests")

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sys.exit(
        "missing dependency: pip install playwright && python -m playwright install chromium"
    )

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import locators  # noqa: E402


# The JS injected into the Meet page. It watches the caption container and
# fires `emitCaption` whenever a block appears or its text changes.
OBSERVER_JS = r"""
(regionSelectors) => {
  const seen = new Map();     // element -> {id, version, lastText}
  let counter = 0;

  function findRegion() {
    for (const sel of regionSelectors) {
      const el = document.querySelector(sel);
      if (el) return el;
    }
    return null;
  }

  function speakerOf(block) {
    for (const sel of ['.zs7s8d', '.KcIKyf', '[class*="name"]']) {
      const el = block.querySelector(sel);
      if (el && el.innerText.trim()) return el.innerText.trim();
    }
    return 'Participant';
  }

  function textOf(block) {
    for (const sel of ['.bh44bd', '.iTTPOb', '[class*="text"]']) {
      const el = block.querySelector(sel);
      if (el && el.innerText.trim()) return el.innerText.trim();
    }
    return block.innerText.trim();
  }

  function scan() {
    const region = findRegion();
    if (!region) return;
    // Caption blocks are the region's element children; if the structure is
    // flatter than expected, fall back to treating the region as one block.
    const blocks = region.children.length ? Array.from(region.children) : [region];
    for (const block of blocks) {
      const text = textOf(block);
      if (!text) continue;
      let rec = seen.get(block);
      if (!rec) {
        rec = { id: 'meet-' + (counter++) + '-' + Date.now(), version: 0, lastText: '' };
        seen.set(block, rec);
      }
      if (text === rec.lastText) continue;
      rec.lastText = text;
      rec.version += 1;
      window.emitCaption(JSON.stringify({
        caption_id: rec.id,
        version: rec.version,
        speaker: speakerOf(block),
        text: text,
      }));
    }
  }

  const region = findRegion();
  const target = region || document.body;
  const observer = new MutationObserver(() => scan());
  observer.observe(target, { childList: true, subtree: true, characterData: true });
  // Belt and braces: Meet sometimes mutates text without firing usable records.
  setInterval(scan, 1000);
  scan();
  return true;
}
"""


def try_click(page, selectors, timeout=2500, label=""):
    """Click the first selector that resolves. Returns True on success."""
    for sel in selectors:
        try:
            el = page.wait_for_selector(sel, timeout=timeout, state="visible")
            if el:
                el.click()
                print(f"  [bot] clicked {label or sel}")
                return True
        except Exception:
            continue
    return False


def try_fill(page, selectors, value, timeout=2500):
    for sel in selectors:
        try:
            el = page.wait_for_selector(sel, timeout=timeout, state="visible")
            if el:
                el.fill(value)
                return True
        except Exception:
            continue
    return False


def wait_for_any(page, selectors, timeout_s):
    """Poll until one of `selectors` exists, or timeout. Returns the match."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        for sel in selectors:
            try:
                if page.query_selector(sel):
                    return sel
            except Exception:
                pass
        time.sleep(1)
    return None


class BrainSender(threading.Thread):
    """Batches captions and POSTs them to the brain's one inlet.

    Runs on its own thread so a slow model call inside IngestChunk (a wake
    phrase fired) never stalls the page or drops captions - they queue up.
    """

    def __init__(self, brain, series, interval=1.5):
        super().__init__(daemon=True)
        self.brain = brain.rstrip("/")
        self.series = series
        self.interval = interval
        self.queue = Queue()
        self.stop_flag = threading.Event()
        self.sent = 0
        self.started_at = time.time()

    def submit(self, payload):
        self.queue.put(payload)

    def run(self):
        while not self.stop_flag.is_set():
            time.sleep(self.interval)
            # Collapse the batch by caption_id so only the newest version of
            # each evolving caption is sent.
            batch = {}
            while True:
                try:
                    item = self.queue.get_nowait()
                except Empty:
                    break
                batch[item["caption_id"]] = item
            for item in batch.values():
                self._post(item)

    def _post(self, item):
        body = {
            "series": self.series,
            "speaker": item["speaker"],
            "text": item["text"],
            "caption_id": item["caption_id"],
            "version": item["version"],
            "ts_ms": int((time.time() - self.started_at) * 1000),
            "source": "meet",
        }
        try:
            resp = requests.post(
                f"{self.brain}/walker/IngestChunk", json=body, timeout=120
            )
            if resp.status_code != 200:
                print(f"  [bot] ingest HTTP {resp.status_code}: {resp.text[:120]}")
                return
            self.sent += 1
            reports = (resp.json().get("data") or {}).get("reports") or []
            for rep in reports:
                if rep.get("wake"):
                    print(f"  [bot] >> wake fired: {rep['wake']!r}")
                if rep.get("kind") == "answer":
                    print(f"  [bot] -> [{rep.get('source')}] {str(rep.get('answer'))[:160]}")
                elif rep.get("kind") == "action":
                    print(f"  [bot] -> [{rep.get('status')}] {rep.get('detail')}")
        except Exception as exc:
            print(f"  [bot] ingest failed: {exc}")


class AnswerWatcher(threading.Thread):
    """Polls the brain for new Answer verdicts and queues them for delivery.

    Only watches - the actual speaking and chat-posting happens on the MAIN
    thread (Playwright's sync API is not thread-safe), which drains
    `self.pending` in the keep-alive loop.
    """

    def __init__(self, brain, series):
        super().__init__(daemon=True)
        self.brain = brain.rstrip("/")
        self.series = series
        self.pending = Queue()
        self.stop_flag = threading.Event()
        self.seen = set()
        self.primed = False

    def run(self):
        while not self.stop_flag.is_set():
            try:
                resp = requests.post(
                    f"{self.brain}/walker/Tick",
                    json={"series": self.series, "after_seq": 10 ** 9},
                    timeout=30,
                )
                reports = (resp.json().get("data") or {}).get("reports") or []
                answers = reports[0].get("answers", []) if reports else []
                for ans in answers:
                    key = str(ans.get("ts_ms"))
                    if key in self.seen:
                        continue
                    self.seen.add(key)
                    # First poll only records what already exists, so joining
                    # mid-meeting doesn't replay every old answer aloud.
                    if self.primed:
                        self.pending.put(ans)
                self.primed = True
            except Exception as exc:
                print(f"  [bot] answer poll failed: {exc}")
            time.sleep(2)


def speak_answer(ans, voice):
    """Play one answer out loud. Never raises.

    Preference order: the server-rendered mp3 (OpenAI tts-1) if it exists,
    else macOS's built-in `say` - which is free, offline, and immune to API
    quota problems.
    """
    if voice == "off":
        return
    text = str(ans.get("answer", ""))[:600]
    if not text:
        return
    mp3 = os.path.join("audio", f"answer-{ans.get('ts_ms')}.mp3")
    # The server writes the mp3 around the same moment we learn of the answer;
    # give it a moment before falling back.
    for _ in range(6):
        if os.path.exists(mp3):
            break
        time.sleep(0.5)

    try:
        if voice == "blackhole":
            # Into the virtual mic -> remote participants hear it.
            if os.path.exists(mp3) and shutil.which("mpv"):
                subprocess.Popen(
                    ["mpv", "--no-video", "--really-quiet",
                     "--audio-device=coreaudio/BlackHole 2ch", mp3],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                subprocess.Popen(["say", "-a", "BlackHole 2ch", text],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:  # auto: this machine's speakers (fine when everyone is in the room)
            if os.path.exists(mp3):
                subprocess.Popen(["afplay", mp3],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                subprocess.Popen(["say", text],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"  [bot] speaking ({voice}): {text[:80]}...")
    except Exception as exc:
        print(f"  [bot] speak failed: {exc}")


def post_to_chat(page, text):
    """Post one message into the Meet chat panel. Best-effort."""
    try:
        # Open the chat panel if the input isn't already visible.
        input_el = None
        for sel in locators.CHAT_INPUT:
            input_el = page.query_selector(sel)
            if input_el:
                break
        if not input_el:
            if not try_click(page, locators.CHAT_OPEN_BUTTON, timeout=3000, label="chat"):
                return False
            time.sleep(1.2)
            for sel in locators.CHAT_INPUT:
                input_el = page.query_selector(sel)
                if input_el:
                    break
        if not input_el:
            return False
        input_el.fill(text[:480])
        time.sleep(0.2)
        if not try_click(page, locators.CHAT_SEND, timeout=1500, label="send"):
            input_el.press("Enter")
        print(f"  [bot] chat: {text[:70]}...")
        return True
    except Exception as exc:
        print(f"  [bot] chat post failed: {exc}")
        return False


def deliver_answer(page, ans, args):
    """One answer -> voice + chat, from the main thread."""
    speak_answer(ans, args.voice)
    if not args.no_chat:
        src = ans.get("source", "")
        post_to_chat(page, f"[Backchannel · {src}] {ans.get('answer', '')}")


def join_meet(page, meet_url, bot_name):
    print(f"  [bot] opening {meet_url}")
    page.goto(meet_url, wait_until="domcontentloaded", timeout=60000)
    time.sleep(4)

    for _ in range(3):
        if not try_click(page, locators.DISMISS_BUTTONS, timeout=1200, label="popup"):
            break
        time.sleep(0.6)

    if try_fill(page, locators.NAME_INPUT, bot_name):
        print(f"  [bot] joining as guest '{bot_name}'")
    else:
        print("  [bot] no name field (signed-in session?) - continuing")

    # Join muted and dark. Non-negotiable: this bot never opens a hot mic.
    try_click(page, locators.MIC_TOGGLE, timeout=2000, label="mic off")
    try_click(page, locators.CAM_TOGGLE, timeout=2000, label="camera off")
    time.sleep(0.5)

    if not try_click(page, locators.JOIN_BUTTONS, timeout=6000, label="join"):
        print("  [bot] !! could not find the join button - check locators.JOIN_BUTTONS")
        return False

    print("  [bot] waiting to be ADMITTED - a human must click Admit in the Meet...")
    hit = wait_for_any(page, locators.IN_CALL_MARKER, timeout_s=180)
    if not hit:
        print("  [bot] !! never got in (not admitted, or IN_CALL_MARKER is stale)")
        return False
    print("  [bot] admitted - in the call")
    return True


def enable_captions(page):
    time.sleep(2)
    if try_click(page, locators.CAPTIONS_BUTTON, timeout=4000, label="captions on"):
        time.sleep(1.5)
        return True
    # Keyboard shortcut is the fallback when the button is behind a menu.
    try:
        page.keyboard.press("c")
        print("  [bot] pressed 'c' for captions")
        time.sleep(1.5)
        return True
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser(description="Backchannel Google Meet capture bot")
    ap.add_argument("--meet-url", required=True)
    ap.add_argument("--series", default="Research Weekly Sync")
    ap.add_argument("--brain", default="http://localhost:8000")
    ap.add_argument("--name", default="Backchannel")
    ap.add_argument("--user-data-dir", default=".jac/bot-profile")
    ap.add_argument(
        "--voice", default="auto", choices=["auto", "blackhole", "off"],
        help="auto: play answers on this machine's speakers; blackhole: play "
             "into the BlackHole virtual mic so REMOTE participants hear the "
             "bot (run setup_voice.sh first); off: text only",
    )
    ap.add_argument("--no-chat", action="store_true",
                    help="don't post answers into the Meet chat")
    args = ap.parse_args()

    sender = BrainSender(args.brain, args.series)
    sender.start()

    with sync_playwright() as p:
        # A persistent profile looks less like a fresh automation session, and
        # --use-fake-ui-for-media-stream auto-accepts the mic/cam permission
        # prompt so the bot never blocks on a native dialog.
        ctx = p.chromium.launch_persistent_context(
            args.user_data_dir,
            headless=False,
            args=[
                "--use-fake-ui-for-media-stream",
                "--disable-blink-features=AutomationControlled",
            ],
            permissions=["microphone", "camera"],
            viewport={"width": 1280, "height": 800},
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        def on_caption(raw):
            try:
                sender.submit(json.loads(raw))
            except Exception as exc:
                print(f"  [bot] bad caption payload: {exc}")

        page.expose_function("emitCaption", on_caption)

        if not join_meet(page, args.meet_url, args.name):
            ctx.close()
            sender.stop_flag.set()
            return 1

        enable_captions(page)

        try:
            page.evaluate(OBSERVER_JS, locators.CAPTION_REGIONS)
            print("  [bot] caption observer installed - streaming to the brain")
        except Exception as exc:
            print(f"  [bot] !! observer failed to install: {exc}")

        if args.voice == "blackhole":
            # The bot joined muted; unmute so the Meet transmits the virtual
            # mic. Cmd+D is Meet's mic toggle on macOS.
            try:
                page.keyboard.press("Meta+d")
                print("  [bot] unmuted (blackhole voice mode)")
            except Exception as exc:
                print(f"  [bot] could not unmute: {exc}")

        watcher = AnswerWatcher(args.brain, args.series)
        watcher.start()

        print(f"  [bot] capturing (voice={args.voice}, chat={'off' if args.no_chat else 'on'}). Ctrl-C to stop.")
        try:
            while True:
                time.sleep(1)
                # Deliver any answers the watcher found (main thread only -
                # Playwright's sync API is not thread-safe).
                while True:
                    try:
                        ans = watcher.pending.get_nowait()
                    except Empty:
                        break
                    deliver_answer(page, ans, args)
                if int(time.time()) % 5 == 0:
                    if not page.query_selector(locators.IN_CALL_MARKER[0]):
                        print("  [bot] call appears to have ended")
                        raise KeyboardInterrupt
        except KeyboardInterrupt:
            print("\n  [bot] stopping")
        finally:
            sender.stop_flag.set()
            watcher.stop_flag.set()
            time.sleep(0.5)
            print(f"  [bot] sent {sender.sent} caption updates")
            ctx.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
