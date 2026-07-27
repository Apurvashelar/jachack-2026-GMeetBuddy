"""Backchannel - the Slack side-channel.

Every meeting series gets a Slack channel (`#bc-<slug>`), auto-created on first
poll. The channel is a two-way surface:

  IN:  post a .md/.txt file      -> it becomes grounding material (RAG docs)
       @Backchannel <question>   -> grounded answer, typed source, in-thread
       @Backchannel transcript   -> the live transcript tail
       @Backchannel summarize    -> force a summary revision and post it

  OUT: answers are posted back to the channel with their source citation, so
       colleagues who couldn't attend still see what the meeting asked.

Deliberately POLL-based (piggybacking on the dashboard's Tick, gated to one
Slack call burst every ~8s): no public HTTPS endpoint, no Socket Mode, no
slash-command registration - one bot token and it runs from a laptop. That is
the difference between "demoable today" and "works after the infra team helps".

Setup: create the Slack app from slack_manifest.yaml, install it to your
workspace, put the bot token in .env as SLACK_BOT_TOKEN. Without a token every
function here no-ops.
"""

import os;
import time;
import requests;

import from graph { MeetingSeries, Session, Answer, now_ms }
import from answer {
    series_of, transcript_of, doc_chunks_of, prior_memory_of, advance_summary
}
import from ai { safe_answer }
import from workspace { workspace_dir, series_slug }


glob POLL_EVERY_S: float = 8.0;

glob _last_poll: float = 0.0;
glob _bot_user: str = "";
glob _channels: dict[str, str] = {};
glob _last_ts: dict[str, str] = {};


"""Is Slack configured at all?"""
def slack_enabled -> bool {
    return len(os.environ.get("SLACK_BOT_TOKEN", "").strip()) > 0;
}


"""One Slack Web API call. Returns the decoded payload, or {} on any failure."""
def slack_api(method: str, params: dict[any], use_get: bool) -> dict[any] {
    token = os.environ.get("SLACK_BOT_TOKEN", "").strip();
    if token == "" {
        return {};
    }
    url = f"https://slack.com/api/{method}";
    headers = {"Authorization": f"Bearer {token}"};
    try {
        if use_get {
            resp = requests.get(url, headers=headers, params=params, timeout=15);
        } else {
            resp = requests.post(url, headers=headers, json=params, timeout=15);
        }
        payload = resp.json();
        if not payload.get("ok", False) {
            print(f"[slack] {method} -> {payload.get('error', 'unknown error')}");
        }
        return payload;
    } except Exception as e {
        print(f"[slack] {method} failed: {str(e)}");
        return {};
    }
}


"""The bot's own Slack user id, cached (used to spot mentions / skip self)."""
def bot_user_id -> str {
    if _bot_user != "" {
        return _bot_user;
    }
    payload = slack_api("auth.test", {}, False);
    _bot_user = str(payload.get("user_id", ""));
    return _bot_user;
}


"""Find or create #bc-<slug> for a series. Returns channel id, "" on failure."""
def ensure_channel(series_name: str) -> str {
    slug = "bc-" + series_slug(series_name)[:70];
    if slug in _channels {
        return _channels[slug];
    }

    cursor = "";
    for _ in range(10) {
        params: dict[any] = {"types": "public_channel", "limit": 200, "exclude_archived": True};
        if cursor != "" {
            params["cursor"] = cursor;
        }
        payload = slack_api("conversations.list", params, True);
        for ch_raw in payload.get("channels", []) {
            ch = ch_raw as dict[any];
            if ch.get("name") == slug {
                cid = str(ch.get("id"));
                _channels[slug] = cid;
                if not ch.get("is_member", False) {
                    slack_api("conversations.join", {"channel": cid}, False);
                }
                return cid;
            }
        }
        cursor = str(payload.get("response_metadata", {}).get("next_cursor", ""));
        if cursor == "" {
            break;
        }
    }

    created = slack_api("conversations.create", {"name": slug}, False);
    cid = str(created.get("channel", {}).get("id", ""));
    if cid != "" {
        _channels[slug] = cid;
        post_message(cid,
            f"*Backchannel connected* for meeting series “{series_name}”.\n"
            "• Post `.md` / `.txt` files here → they become grounding docs for answers.\n"
            "• Mention me with a question → grounded answer with a typed source.\n"
            "• `@Backchannel transcript` → live transcript tail. `@Backchannel summarize` → current summary.");
    }
    return cid;
}


"""Post one message to a channel."""
def post_message(channel: str, text: str) {
    slack_api("chat.postMessage", {"channel": channel, "text": text[:3500]}, False);
}


"""Download a file Slack shared into the channel to the series' docs folder.
Only text formats we can actually ingest."""
def save_slack_file(series_name: str, finfo: dict[any]) -> str {
    name = str(finfo.get("name", "upload.txt"));
    lower = name.lower();
    if not (lower.endswith(".md") or lower.endswith(".txt") or lower.endswith(".markdown")) {
        return "";
    }
    url = str(finfo.get("url_private_download", ""));
    if url == "" {
        return "";
    }
    token = os.environ.get("SLACK_BOT_TOKEN", "").strip();
    try {
        resp = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=30);
        if resp.status_code != 200 {
            return "";
        }
        safe = "".join([c if (c.isalnum() or c in "._-") else "-" for c in name]);
        dest = os.path.join(workspace_dir(series_name), "docs", safe);
        with open(dest, "wb") as fh {
            fh.write(resp.content);
        }
        return safe;
    } except Exception as e {
        print(f"[slack] file download failed: {str(e)}");
        return "";
    }
}


"""Answer a question asked from Slack: same evidence assembly as the voice
path, persisted as an Answer node so it also shows on the dashboard.

Plain function, not a walker spawn - this runs inside Tick, and a nested
walker's reports would shift the payload the dashboard reads."""
def slack_answer(series: MeetingSeries, session: Session, ask: str) -> str {
    verdict = safe_answer(
        ask,
        doc_chunks_of(series),
        transcript_of(session, 60),
        prior_memory_of(series)
    );
    session ++> Answer(
        question=ask, answer=verdict.answer, source=verdict.source,
        quote=verdict.quote, seq=session.next_seq, ts_ms=now_ms()
    );
    reply = f"*[{verdict.source}]* {verdict.answer}";
    if verdict.quote.strip() != "" {
        reply += f"\n> {verdict.quote[:280]}";
    }
    return reply;
}


"""Strip the bot mention off a message; "" when the bot wasn't addressed."""
def extract_ask(text: str) -> str {
    me = bot_user_id();
    mention = f"<@{me}>";
    if me != "" and mention in text {
        return text.replace(mention, " ").strip(" ,.:;!-");
    }
    lowered = text.lower();
    for prefix in ["hey jac", "!jac", "jac:"] {
        if lowered.startswith(prefix) {
            return text[len(prefix):].strip(" ,.:;!-");
        }
    }
    return "";
}


"""The poll: called from Tick, self-gated to one pass per POLL_EVERY_S.

Returns True when new documents landed and the graph's docs need reloading."""
def slack_poll(session: Session) -> bool {
    if not slack_enabled() {
        return False;
    }
    now = time.time();
    if now - _last_poll < POLL_EVERY_S {
        return False;
    }
    _last_poll = now;

    series = series_of(session);
    if series is None {
        return False;
    }
    channel = ensure_channel(series.name);
    if channel == "" {
        return False;
    }

    # First sight of the channel: mark "now" and only react to what follows,
    # so a server restart doesn't replay week-old messages.
    if channel not in _last_ts {
        _last_ts[channel] = str(now);
        return False;
    }

    payload = slack_api("conversations.history",
        {"channel": channel, "oldest": _last_ts[channel], "limit": 30}, True);
    messages = payload.get("messages", []);
    if not messages {
        return False;
    }

    docs_dirty = False;
    me = bot_user_id();
    # Slack returns newest first; process in the order people wrote them.
    for msg_raw in reversed(messages) {
        msg = msg_raw as dict[any];
        ts = str(msg.get("ts", ""));
        if ts != "" and float(ts) > float(_last_ts[channel]) {
            _last_ts[channel] = ts;
        }
        if msg.get("bot_id") or str(msg.get("user", "")) == me {
            continue;
        }

        for finfo_raw in msg.get("files", []) {
            saved = save_slack_file(series.name, finfo_raw as dict[any]);
            if saved != "" {
                docs_dirty = True;
                post_message(channel, f"Loaded *{saved}* into this meeting's grounding docs.");
            }
        }

        ask = extract_ask(str(msg.get("text", "")));
        if ask == "" {
            continue;
        }
        lowered = ask.lower();
        if lowered.startswith("transcript") {
            tail = transcript_of(session, 15);
            post_message(channel, f"*Live transcript (last 15 lines):*\n```{tail or '(nothing yet)'}```");
        } elif lowered.startswith("summar") {
            advance_summary(session, True);
            post_message(channel, f"*Rolling summary:*\n{session.summary or '_no summary yet_'}");
        } else {
            post_message(channel, slack_answer(series, session, ask));
        }
    }
    return docs_dirty;
}
