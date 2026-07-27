"""Backchannel - the `/backchannel` Slack slash command.

    /backchannel start <meet-link> <Project Name>   send the bot into a meeting
    /backchannel <Project> transcripts              full transcript
    /backchannel <Project> summarized transcripts   the distilled version
    /backchannel <Project> ask <question>           grounded answer, cited
    /backchannel <Project> load <url>               add a URL to the knowledge
    /backchannel <Project> docs                     what it is grounded in
    /backchannel projects                           everything Backchannel knows

Slack posts `application/x-www-form-urlencoded` to ONE public URL, which is why
this lives behind `@restspec(path="/slack/command")` rather than the default
`/walker/<Name>` route - Slack will not send a JSON body.

Slash commands demand a reply within **3 seconds** or Slack shows an operation
timeout. Anything slower (fetching a PDF, asking a model) is acknowledged
immediately and the real answer is posted afterwards to the `response_url`
Slack hands us. That is why this file is shaped the way it is.

Requests are authenticated with Slack's HMAC signature - the endpoint is public
on the internet, so an unsigned request must not be able to drive the bot.
"""

import os;
import re;
import time;
import hmac;
import hashlib;
import threading;
import requests;

import from graph {
    MeetingSeries, Session, Utterance, Doc, SessionSummary, get_series
}
import from workspace { workspace_dir, read_context_file }
import from sources { find_urls, ingest_url, ingest_text }


glob SLACK_SIGNING_SECRET: str = os.environ.get("SLACK_SIGNING_SECRET", "");


"""Verify Slack's HMAC signature. True when the request is genuine.

Skipped only when no signing secret is configured (local development) - a
deployed instance without this is an open remote-control endpoint."""
def verify_slack(body: str, timestamp: str, signature: str) -> bool {
    if SLACK_SIGNING_SECRET == "" {
        print("[slash] SLACK_SIGNING_SECRET unset - skipping verification (dev only)");
        return True;
    }
    if timestamp == "" or signature == "" {
        return False;
    }
    try {
        # Reject replays of old captured requests.
        if abs(time.time() - float(timestamp)) > 300 {
            return False;
        }
    } except Exception {
        return False;
    }
    base = f"v0:{timestamp}:{body}";
    # bytes(...) rather than str.encode(): the checker types the latter as str.
    key: bytes = bytes(SLACK_SIGNING_SECRET, "utf-8");
    payload: bytes = bytes(base, "utf-8");
    digest = hmac.new(key, payload, hashlib.sha256).hexdigest();
    # Both sides as bytes: compare_digest is typed for buffers, and this keeps
    # the comparison constant-time (never use == for signature checks).
    expected: bytes = bytes(f"v0={digest}", "utf-8");
    got: bytes = bytes(signature, "utf-8");
    return hmac.compare_digest(expected, got);
}


"""Post a delayed reply to the response_url Slack gave us."""
def respond_later(response_url: str, text: str, public: bool) {
    if response_url == "" {
        return;
    }
    try {
        requests.post(response_url, json={
            "text": text[:3800],
            "response_type": "in_channel" if public else "ephemeral"
        }, timeout=15);
    } except Exception as e {
        print(f"[slash] delayed reply failed: {str(e)}");
    }
}


"""The transcript of a project's most recent session."""
def project_transcript(series_name: str, limit: int) -> str {
    series = get_series(series_name);
    sessions = [series -->[?:Session]];
    if len(sessions) == 0 {
        return "";
    }
    latest = sessions[-1];
    lines: list[str] = [];
    for u in [latest -->[?:Utterance]] {
        lines.append(f"{u.speaker}: {u.text}");
    }
    return "\n".join(lines[-limit:]);
}


"""Every project Backchannel has seen, with its caption count."""
def list_projects -> str {
    rows: list[str] = [];
    for s in [root -->[?:MeetingSeries]] {
        total = 0;
        for sess in [s -->[?:Session]] {
            total += sess.next_seq;
        }
        rows.append(f"• *{s.name}* - {total} captions");
    }
    if len(rows) == 0 {
        return "No projects yet. Start one with `/backchannel start <meet-link> <Project Name>`.";
    }
    return "*Projects Backchannel knows about:*\n" + "\n".join(rows);
}


"""Status card for one project."""
def project_status(series_name: str) -> str {
    series = get_series(series_name);
    total = 0;
    live = False;
    for sess in [series -->[?:Session]] {
        total += sess.next_seq;
        if sess.live {
            live = True;
        }
    }
    docs: list[str] = [];
    for d in [series -->[?:Doc]] {
        docs.append(d.title);
    }
    memories = len([series -->[?:SessionSummary]]);
    lines = [
        f"*{series_name}*",
        f"• {total} captions captured" + (" _(session live)_" if live else ""),
        f"• {len(docs)} grounding doc(s): " + (", ".join(docs[:6]) if docs else "_none yet_"),
        f"• {memories} prior session(s) in memory"
    ];
    return "\n".join(lines);
}


glob HELP_TEXT: str = """*Backchannel* - your meeting's memory.

`/backchannel start <meet-link> <Project>` - send the bot into a meeting
`/backchannel <Project> ask <question>` - grounded answer with a source citation
`/backchannel <Project> transcripts` - the raw transcript
`/backchannel <Project> summarized transcripts` - the distilled version
`/backchannel <Project> load <url>` - add a URL to the searchable knowledge (RAG)
`/backchannel <Project> pin <text or url>` - always-in-context briefing
`/backchannel <Project> docs` - list what the project is grounded in
`/backchannel projects` - everything Backchannel knows

Attach PDFs or paste links in the project's channel and they become grounding
material automatically.""";


obj ParsedCommand {
    has action: str = "help",
        project: str = "",
        meet_url: str = "",
        rest: str = "";
}


"""Parse the free text after /backchannel into an intent.

Deliberately forgiving about word order and casing, because people type these
one-handed during a meeting. Project names may contain spaces, so the verb is
located first and everything before it is the project."""
def parse_command(raw: str) -> ParsedCommand {
    text = " ".join(raw.split());
    if text == "" or text.lower() in ["help", "-h", "--help"] {
        return ParsedCommand(action="help");
    }
    lowered = text.lower();

    if lowered.startswith("projects") or lowered == "list" {
        return ParsedCommand(action="projects");
    }

    # start <meet-link> <Project Name>  ("start" optional)
    meet = "";
    for u in find_urls(text) {
        if "meet.google.com" in u {
            meet = u;
            break;
        }
    }
    if meet != "" {
        remainder = text.replace(meet, " ");
        for word in ["start", "join", "launch"] {
            remainder = str(re.sub(rf"(?i)\b{word}\b", " ", remainder));
        }
        return ParsedCommand(
            action="start", project=" ".join(remainder.split()), meet_url=meet
        );
    }

    # <Project> <verb> [rest...] - longest phrases first so "summarized
    # transcripts" is not shadowed by "transcripts".
    verbs = [
        ("summarized transcripts", "summary"), ("summarised transcripts", "summary"),
        ("summarized transcript", "summary"), ("summary", "summary"),
        ("transcripts", "transcript"), ("transcript", "transcript"),
        ("ask", "ask"), ("question", "ask"),
        ("load", "load"), ("add", "load"),
        ("pin", "pin"), ("brief", "pin"), ("context", "pin"),
        ("docs", "docs"), ("documents", "docs"),
        ("stop", "stop"), ("end", "end")
    ];
    for (phrase, action) in verbs {
        marker = " " + phrase;
        if marker in lowered {
            idx = lowered.index(marker);
            project = text[:idx].strip();
            rest = text[idx + len(marker):].strip();
            if project != "" {
                return ParsedCommand(action=action, project=project, rest=rest);
            }
        }
        if lowered.startswith(phrase + " ") {
            # Verb first: "transcripts MyProject"
            return ParsedCommand(action=action, project=text[len(phrase):].strip());
        }
    }

    # A bare project name shows its status.
    return ParsedCommand(action="status", project=text);
}


"""Do the slow work for one command and post the result back to Slack.

Runs on a background thread: model calls, PDF fetches and bot launches all
take longer than Slack's 3-second budget."""
def execute_command(cmd: ParsedCommand, response_url: str, user: str) {
    import from ingest { reload_docs }
    import from answer { AnswerQuestion, series_of, transcript_of, doc_chunks_of, prior_memory_of }
    import from ai { safe_answer, safe_distill }
    import from botctl { bot_capability }
    import from graph { get_live_session }

    try {
        if cmd.action == "projects" {
            respond_later(response_url, list_projects(), False);
            return;
        }
        if cmd.action == "help" {
            respond_later(response_url, HELP_TEXT, False);
            return;
        }
        if cmd.project == "" {
            respond_later(response_url, "Which project? Try `/backchannel projects`.", False);
            return;
        }

        series = get_series(cmd.project);

        if cmd.action == "start" {
            blocked = bot_capability();
            if blocked != "" {
                respond_later(response_url,
                    f"*{cmd.project}* is ready and its workspace exists, but I cannot send a bot from this server.\n> {blocked}",
                    False);
                return;
            }
            import from botctl { StartBot }
            result = root spawn StartBot(series=cmd.project, meet_url=cmd.meet_url);
            rep = result.reports[0] if result.reports else {};
            if rep.get("ok") {
                respond_later(response_url,
                    f":satellite: Backchannel is joining *{cmd.project}*.\n{rep.get('note')}\nWorkspace: `{workspace_dir(cmd.project)}`",
                    True);
            } else {
                respond_later(response_url, f":warning: {rep.get('error')}", False);
            }
            return;
        }

        if cmd.action == "transcript" {
            text = project_transcript(cmd.project, 60);
            if text.strip() == "" {
                respond_later(response_url, f"No transcript for *{cmd.project}* yet.", False);
            } else {
                respond_later(response_url, f"*Transcript - {cmd.project}*\n```{text[:3200]}```", False);
            }
            return;
        }

        if cmd.action == "summary" {
            text = project_transcript(cmd.project, 400);
            if text.strip() == "" {
                # No live transcript, but past sessions may be distilled already.
                memory = read_context_file(cmd.project);
                if memory.strip() != "" {
                    respond_later(response_url, f"*Memory - {cmd.project}*\n{memory[:3200]}", False);
                } else {
                    respond_later(response_url, f"Nothing to summarize for *{cmd.project}* yet.", False);
                }
                return;
            }
            distilled = safe_distill(text);
            out = f"*Summary - {cmd.project}*\n{distilled.bullets}";
            if distilled.decisions.strip() != "" {
                out += f"\n\n*Decisions*\n{distilled.decisions}";
            }
            respond_later(response_url, out, True);
            return;
        }

        if cmd.action == "ask" {
            if cmd.rest.strip() == "" {
                respond_later(response_url, "Ask what? `/backchannel <Project> ask <question>`", False);
                return;
            }
            session = get_live_session(series);
            verdict = safe_answer(
                cmd.rest,
                doc_chunks_of(series),
                transcript_of(session, 60),
                prior_memory_of(series)
            );
            out = f"*[{verdict.source}]* {verdict.answer}";
            if verdict.quote.strip() != "" {
                out += f"\n> {verdict.quote[:280]}";
            }
            respond_later(response_url, out, True);
            return;
        }

        if cmd.action == "load" {
            urls = find_urls(cmd.rest);
            if len(urls) == 0 {
                respond_later(response_url, "Give me a URL: `/backchannel <Project> load https://...`", False);
                return;
            }
            loaded: list[str] = [];
            for u in urls {
                name = ingest_url(cmd.project, u);
                if name != "" {
                    loaded.append(name);
                }
            }
            if len(loaded) == 0 {
                respond_later(response_url, "I could not read anything usable from that link.", False);
                return;
            }
            total = reload_docs(series);
            respond_later(response_url,
                f":books: Added {len(loaded)} source(s) to *{cmd.project}*: {', '.join(loaded)}\nNow grounded in {len(total)} document(s).",
                True);
            return;
        }

        if cmd.action == "pin" {
            if cmd.rest.strip() == "" {
                respond_later(response_url,
                    "Pin what? `/backchannel <Project> pin <text>` or `pin <url>`", False);
                return;
            }
            urls = find_urls(cmd.rest);
            if len(urls) > 0 {
                pinned: list[str] = [];
                for u in urls {
                    name = ingest_url(cmd.project, u, "direct");
                    if name != "" {
                        pinned.append(name);
                    }
                }
                if len(pinned) == 0 {
                    respond_later(response_url, "I could not read anything usable from that link.", False);
                    return;
                }
                reload_docs(series);
                respond_later(response_url,
                    f":pushpin: Pinned to *{cmd.project}*: {', '.join(pinned)}. This is now sent with every answer.", True);
                return;
            }
            name = ingest_text(cmd.project, f"pinned-{int(time.time())}", cmd.rest);
            reload_docs(series);
            respond_later(response_url,
                f":pushpin: Pinned to *{cmd.project}*. Every answer will now see:\n> {cmd.rest[:280]}", True);
            return;
        }

        if cmd.action == "docs" {
            rag: list[str] = [];
            pins: list[str] = [];
            for d in [series -->[?:Doc]] {
                if d.mode == "direct" {
                    pins.append(d.title);
                } else {
                    rag.append(d.title);
                }
            }
            if len(rag) == 0 and len(pins) == 0 {
                respond_later(response_url,
                    f"*{cmd.project}* has no sources yet. `load <url>` for searchable material, `pin <text>` for always-on context.", False);
                return;
            }
            out = f"*{cmd.project}* sources";
            if len(pins) > 0 {
                out += "\n\n*Pinned* _(sent with every answer)_\n" + "\n".join([f"• {n}" for n in pins]);
            }
            if len(rag) > 0 {
                out += "\n\n*Searchable* _(retrieved by relevance)_\n" + "\n".join([f"• {n}" for n in rag]);
            }
            respond_later(response_url, out, False);
            return;
        }

        if cmd.action in ["stop", "end"] {
            import from answer { EndSession }
            import from botctl { StopBot }
            root spawn StopBot();
            root spawn EndSession(series=cmd.project);
            respond_later(response_url,
                f":checkered_flag: Closed *{cmd.project}* and distilled it into memory. Next session will remember this one.", True);
            return;
        }

        respond_later(response_url, project_status(cmd.project), False);
    } except Exception as e {
        print(f"[slash] command failed: {str(e)}");
        respond_later(response_url, f":warning: That failed: {str(e)[:300]}", False);
    }
}


@restspec(path="/slack/command")
walker:pub SlackCommand {
    """The one public URL Slack posts every /backchannel invocation to.

    Slack sends form-encoded fields, so each `has` below mirrors one of them.
    We answer within milliseconds and finish the work on a background thread -
    Slack gives us three seconds, and a model call alone can take five.
    """

    has command: str = "",
        text: str = "",
        user_name: str = "",
        channel_name: str = "",
        response_url: str = "",
        reports: list[dict[any]] = [];

    can run with Root entry {
        cmd = parse_command(self.text);

        # Instant acknowledgement, then the real work off-thread.
        if cmd.action == "help" {
            report {"response_type": "ephemeral", "text": HELP_TEXT};
            disengage;
        }

        url = self.response_url;
        who = self.user_name;
        worker = lambda { execute_command(cmd, url, who); };
        threading.Thread(target=worker, daemon=True).start();

        ack = {
            "start": f":satellite: Sending Backchannel into *{cmd.project}*...",
            "transcript": f":page_facing_up: Fetching the transcript for *{cmd.project}*...",
            "summary": f":brain: Summarizing *{cmd.project}*...",
            "ask": f":mag: Looking that up in *{cmd.project}*...",
            "load": ":books: Reading that source...",
            "pin": ":pushpin: Pinning that to the meeting...",
            "docs": f":books: Checking what *{cmd.project}* knows...",
            "projects": ":file_folder: Listing projects...",
            "stop": f":checkered_flag: Closing *{cmd.project}*...",
            "end": f":checkered_flag: Closing *{cmd.project}*..."
        }.get(cmd.action, f":mag: Working on *{cmd.project}*...");

        report {"response_type": "ephemeral", "text": ack};
    }
}
