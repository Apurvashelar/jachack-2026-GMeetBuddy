"""Backchannel - the single inlet, and the client's polling cursor.

`IngestChunk` is the ONE door into the graph. The Playwright ears, the scripted
replay and the Attendee parachute all speak the same JSON, so the brain never
knows or cares which pair of ears it is wearing.

The trigger path is deliberately dumb: wake detection is a lowercase substring
scan, not a model call. Zero LLM calls happen on ingest unless a human actually
said the wake phrase.
"""

import from graph {
    MeetingSeries, Session, Utterance, Answer, Action, Doc, DocChunk,
    SessionSummary, now_ms, now_iso, get_series, get_live_session
}
import from answer { handle_wake, advance_summary }
import from workspace { list_workspace_docs, workspace_dir, chunk_text }
import from slackbridge { slack_poll }
import from adapters { fetch_repo_docs }
import from sources { find_urls, ingest_url, ingest_text, ingest_blob }
import from botctl { bot_running, bot_log_tail, pending_requests }


# Ordered LONGEST FIRST. "hey jac" is a prefix of "hey jack", so a short-first
# scan would match "hey jac" inside "Hey Jack, how are you?" and leave the ask
# as "k, how are you?" - which is exactly the bug this ordering prevents.
# Longest first, because "hey jac" is a prefix of "hey jack". The misheard
# variants are here because Google's ASR reliably renders "Hey Jac" as "Hey
# Jeff", "Okay Jack" or "Hey Jack" depending on accent and mic - and a wake
# word that only works when the transcriber cooperates is not a wake word.
glob WAKE_PHRASES: list[str] = [
    "hey jacques", "okay jack", "okay jac", "hey jack", "hey jeff", "hey check",
    "ok jack", "ok jac", "hey jac", "hey jak", "a jack", "hey jax"
];

"""Every wake phrase in a block of text, with the ask that follows each.

Google Meet does not give one caption per sentence - it streams a whole turn
into a single block that keeps growing, so one block routinely contains three
questions. Detecting only the first would silently drop the rest, which is
exactly the bug this replaces. Each ask is cut at the next wake phrase or at
the question mark, so "Hey Jac, what is X? Hey Jac, what is Y?" yields two
clean questions rather than one run-on.

No model, no network, no cost - this is still just a lowercase scan."""
def detect_wake_all(text: str) -> list[str] {
    lowered = text.lower();
    # Collect every (position, phrase-length) hit across all spellings.
    hits: list[tuple] = [];
    for phrase in WAKE_PHRASES {
        start = 0;
        while True {
            if phrase not in lowered[start:] {
                break;
            }
            idx = lowered.index(phrase, start);
            hits.append((idx, len(phrase)));
            start = idx + len(phrase);
        }
    }
    if len(hits) == 0 {
        return [];
    }
    hits.sort();

    # Drop overlapping hits: "hey jack" and "hey jac" both match the same words.
    clean: list[tuple] = [];
    last_end: int = -1;
    for h in hits {
        start_at: int = int(h[0]);
        span_len: int = int(h[1]);
        if start_at >= last_end {
            clean.append(h);
            last_end = start_at + span_len;
        }
    }

    asks: list[str] = [];
    for (i, h) in enumerate(clean) {
        begin: int = int(h[0]) + int(h[1]);
        stop: int = len(text);
        if i + 1 < len(clean) {
            stop = int(clean[i + 1][0]);
        }
        span = text[begin:stop];
        # A question mark ends the ask - anything after it is the next thought.
        if "?" in span {
            span = span[:span.index("?") + 1];
        }
        cleaned = span.strip(" ,.?!:;-");
        if cleaned != "" {
            asks.append(cleaned);
        }
    }
    return asks;
}


"""The first ask in a block, or "" - kept for callers that want just one."""
def detect_wake(text: str) -> str {
    asks = detect_wake_all(text);
    return asks[0] if len(asks) > 0 else "";
}


"""Serialize an Utterance for the wire."""
def utt_dict(u: Utterance) -> dict[any] {
    return {
        "seq": u.seq, "speaker": u.speaker, "text": u.text,
        "caption_id": u.caption_id, "version": u.version, "ts_ms": u.ts_ms
    };
}


"""Serialize an Answer for the wire."""
def answer_dict(a: Answer) -> dict[any] {
    return {
        "seq": a.seq, "question": a.question, "answer": a.answer,
        "source": a.source, "quote": a.quote, "ts_ms": a.ts_ms
    };
}


"""Serialize an Action receipt for the wire."""
def action_dict(a: Action) -> dict[any] {
    return {
        "seq": a.seq, "kind": a.kind, "payload": a.payload,
        "result_url": a.result_url, "status": a.status,
        "detail": a.detail, "ts_ms": a.ts_ms
    };
}


walker:pub IngestChunk {
    """The inlet. Walks root -> series -> session, then upserts one caption.

    Upsert-by-caption_id is what makes the ears cheap: Google Meet rewrites a
    caption block many times as the speaker talks, so the bot can redeliver the
    same `caption_id` with a higher `version` as liberally as it likes.
    """

    has series: str,
        speaker: str = "Speaker",
        text: str = "",
        caption_id: str = "",
        version: int = 0,
        ts_ms: int = -1,
        source: str = "replay",
        final: bool = True,
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        visit get_series(self.series);
    }

    can at_series with MeetingSeries entry {
        visit get_live_session(here);
    }

    can at_session with Session entry {
        here.source = self.source;
        cid = self.caption_id;
        if cid == "" {
            cid = f"auto-{here.next_seq}";
        }
        # -1 means "the ears did not supply a timestamp"; 0 is a real value
        # (the first line of a replay) and must not be overwritten.
        stamp = self.ts_ms;
        if stamp < 0 {
            stamp = now_ms();
        }

        existing: Utterance | None = None;
        for u in [here -->[?:Utterance]] {
            if u.caption_id == cid {
                existing = u;
                break;
            }
        }

        changed = False;
        utt: Utterance | None = existing;
        if existing is None {
            utt = here ++> Utterance(
                speaker=self.speaker, text=self.text, caption_id=cid,
                version=self.version, seq=here.next_seq, ts_ms=stamp
            );
            here.next_seq += 1;
            changed = True;
        } elif self.version >= existing.version and self.text != existing.text {
            existing.text = self.text;
            existing.version = self.version;
            existing.speaker = self.speaker;
            changed = True;
        }

        # The trigger path: a lowercase substring scan. Zero model calls happen
        # here unless a human actually said the phrase.
        #
        # Live captions arrive as growing fragments ("hey jac what" -> "hey jac
        # what is" -> ...). Answering each fragment would fire several half-
        # questions per sentence, so we wait for the ears to mark the caption
        # final (text stopped changing) and answer each caption exactly once.
        # The trigger path. A growing caption block can accumulate several
        # questions, so we track HOW MANY asks this block has already been
        # answered for rather than a single done/not-done flag - otherwise
        # question two and three in the same breath are silently dropped.
        ask = "";
        routed: dict[any] = {};
        if changed and utt is not None {
            asks = detect_wake_all(utt.text);
            while utt.wake_count < len(asks) {
                candidate = asks[utt.wake_count];
                # Only answer once the ask reads as finished: a question mark,
                # a later ask already started behind it, or the ears calling
                # the caption final.
                settled = candidate.endswith("?")
                          or utt.wake_count < len(asks) - 1
                          or self.final
                          or len(candidate.split()) >= 6;
                if not settled {
                    break;
                }
                # Everything after the first ask in a block came from the same
                # human breath, so it bypasses the echo guard.
                same_breath = utt.wake_count > 0;
                utt.wake_count += 1;
                utt.wake_done = True;
                ask = candidate;
                routed = handle_wake(here, candidate, utt.seq, utt.text, same_breath);
            }
        }
        report {
            "ok": True, "seq": utt.seq if utt is not None else -1,
            "changed": changed, "wake": ask, "routed": routed
        };
    }
}


walker:pub Tick {
    """The client's heartbeat: everything new since `after_seq`, in one hop.

    Spawned by the dashboard every ~2s. A walker spawn rather than a reader RPC
    on purpose - reader responses are cached for 60s, which would freeze a feed
    whose whole point is being live.
    """

    has series: str,
        after_seq: int = -1,
        memory_cache: list[dict[any]] = [],
        doc_titles: list[str] = [],
        pinned_titles: list[str] = [],
        doc_chunks: int = 0,
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        visit get_series(self.series);
    }

    can at_series with MeetingSeries entry {
        memory: list[dict[any]] = [];
        for m in [here -->[?:SessionSummary]] {
            memory.append({
                "bullets": m.bullets, "decisions": m.decisions,
                "started_at": m.started_at
            });
        }
        titles: list[str] = [];
        pinned: list[str] = [];
        chunk_count = 0;
        for d in [here -->[?:Doc]] {
            if d.mode == "direct" {
                pinned.append(d.title);
            } else {
                titles.append(d.title);
            }
            chunk_count += len([d -->[?:DocChunk]]);
        }
        self.memory_cache = memory;
        self.doc_titles = titles;
        self.pinned_titles = pinned;
        self.doc_chunks = chunk_count;
        visit get_live_session(here);
    }

    can at_session with Session entry {
        # Slack side-channel: gated inside slack_poll to ~one pass per 8s and
        # a no-op without SLACK_BOT_TOKEN. New files posted in the channel land
        # in docs/ - reload them into the graph here.
        if slack_poll(here) {
            for s in [here <--[?:MeetingSeries]] {
                reload_docs(s);
            }
        }

        # Server-side summary cadence: the gate inside `advance_summary` means
        # this is a no-op on most ticks.
        advance_summary(here, False);

        fresh: list[dict[any]] = [];
        # Graph references come back in edge-creation order, which for utterances
        # IS seq order - no sort needed.
        for u in [here -->[?:Utterance]] {
            if u.seq > self.after_seq {
                fresh.append(utt_dict(u));
            }
        }

        answers: list[dict[any]] = [];
        for a in [here -->[?:Answer]] {
            answers.append(answer_dict(a));
        }

        actions: list[dict[any]] = [];
        for a in [here -->[?:Action]] {
            actions.append(action_dict(a));
        }

        report {
            "series": self.series,
            "utterances": fresh,
            "cursor": here.next_seq - 1,
            "summary": here.summary,
            "summary_seq": here.summary_seq,
            "answers": answers,
            "actions": actions,
            "live": here.live,
            "started_at": here.started_at,
            "source": here.source,
            "total": here.next_seq,
            "memory": self.memory_cache,
            "doc_titles": self.doc_titles,
            "pinned_titles": self.pinned_titles,
            "doc_chunks": self.doc_chunks,
            "bot_running": bot_running(),
            "bot_queued": pending_requests(),
            "bot_log": bot_log_tail(2),
            "workspace": workspace_dir(self.series)
        };
    }
}


"""Replace a series' graph docs with whatever is in its docs/ folder."""
def reload_docs(series: MeetingSeries) -> list[str] {
    found = list_workspace_docs(series.name);
    for old in [series -->[?:Doc]] {
        del old;
    }
    # Both drop-zones are rescanned above, so a full replace is correct here.
    loaded: list[str] = [];
    for row in found {
        fname = str(row[0]);
        text = str(row[1]);
        mode = str(row[2]);
        doc = series ++> Doc(title=fname, mode=mode);
        # A pinned doc is never chunked for retrieval - it is sent whole.
        if mode == "direct" {
            doc ++> DocChunk(text=text, idx=0);
        } else {
            for (i, piece) in enumerate(chunk_text(text)) {
                doc ++> DocChunk(text=piece, idx=i);
            }
        }
        loaded.append(fname);
    }
    return loaded;
}


walker:pub StartMeeting {
    """Open a clean session for a project, closing whatever was live before.

    This is what makes the tool demoable: pointing it at a new meeting must not
    leave the previous meeting's captions on screen. Any live session is closed
    and a fresh one opened, so the feed and counters start from zero.
    """

    has series: str,
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        visit get_series(self.series);
    }

    can at_series with MeetingSeries entry {
        closed = 0;
        for sess in [here -->[?:Session]] {
            if sess.live {
                sess.live = False;
                closed += 1;
            }
        }
        fresh = get_live_session(here);
        loaded = reload_docs(here);
        report {
            "ok": True, "series": self.series, "closed": closed,
            "started_at": fresh.started_at, "docs": len(loaded)
        };
    }
}


walker:pub ForgetProject {
    """Delete a meeting and everything under it.

    Rehearsing creates junk projects, and a switcher full of "test", "smoke"
    and typos is the kind of thing an audience reads instead of your demo.
    Deleting a node cascades to its edges, so removing the series takes its
    sessions, utterances, answers and docs with it. The workspace folder on
    disk is deliberately left alone - transcripts and context files are the
    user's, not ours to bin.
    """

    has series: str,
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        for s in [root -->[?:MeetingSeries]] {
            if s.name != self.series {
                continue;
            }
            for sess in [s -->[?:Session]] {
                for u in [sess -->[?:Utterance]] { del u; }
                for a in [sess -->[?:Answer]] { del a; }
                for a in [sess -->[?:Action]] { del a; }
                del sess;
            }
            for d in [s -->[?:Doc]] {
                for c in [d -->[?:DocChunk]] { del c; }
                del d;
            }
            for m in [s -->[?:SessionSummary]] { del m; }
            del s;
            report {"ok": True, "forgot": self.series};
            disengage;
        }
        report {"ok": False, "error": f"No meeting called '{self.series}'."};
    }
}


walker:pub Projects {
    """Every project on the graph, newest activity first - the switcher's data."""

    has reports: list[dict[any]] = [];

    can at_root with Root entry {
        rows: list[dict[any]] = [];
        for s in [root -->[?:MeetingSeries]] {
            total = 0;
            live = False;
            for sess in [s -->[?:Session]] {
                total += sess.next_seq;
                if sess.live {
                    live = True;
                }
            }
            rows.append({"name": s.name, "captions": total, "live": live});
        }
        report {"projects": rows};
    }
}


walker:pub SyncWorkspace {
    """Reload the series' grounding docs from its meetings/<slug>/docs/ folder.

    Drop .md or .txt files in the folder, click Sync on the dashboard (or POST
    here), and they replace whatever docs were previously attached. This is the
    "hand the bot a document" path for humans; LoadDoc below is the same thing
    for scripts.
    """

    has series: str,
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        visit get_series(self.series);
    }

    can at_series with MeetingSeries entry {
        loaded = reload_docs(here);
        if len(loaded) == 0 {
            report {"ok": False, "loaded": [],
                    "error": f"No .md/.txt files in {workspace_dir(self.series)}/docs/"};
            disengage;
        }
        report {"ok": True, "loaded": loaded};
    }
}


walker:pub AddSource {
    """Add knowledge from the dashboard - four shapes, two destinations.

    mode="rag"    -> chunked, retrieved by relevance (papers, wikis, specs)
    mode="direct" -> sent verbatim with every answer (agenda, glossary)

    and the payload is any of: a URL to fetch, literal text, or a file
    delivered as base64. Files arrive base64-in-JSON rather than as multipart
    so the whole client stays on the same typed walker-spawn path as everything
    else - no separate upload endpoint, no form encoding.
    """

    has series: str,
        mode: str = "rag",
        url: str = "",
        text: str = "",
        title: str = "briefing",
        filename: str = "",
        content_b64: str = "",
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        visit get_series(self.series);
    }

    can at_series with MeetingSeries entry {
        added: list[str] = [];

        if self.content_b64 != "" and self.filename != "" {
            import base64;
            try {
                blob = base64.b64decode(self.content_b64);
                name = ingest_blob(self.series, self.filename, blob, self.mode);
                if name == "" {
                    report {"ok": False,
                            "error": f"{self.filename}: unsupported or unreadable. PDF, .md and .txt only."};
                    disengage;
                }
                added.append(name);
            } except Exception as e {
                report {"ok": False, "error": f"Could not read {self.filename}: {str(e)}"};
                disengage;
            }
        }

        for u in find_urls(self.url + " " + self.text) {
            name = ingest_url(self.series, u, self.mode);
            if name != "" {
                added.append(name);
            }
        }
        # Literal text only makes sense as direct context - retrieval over a
        # single pasted paragraph would be theatre.
        if self.mode == "direct" and self.text.strip() != "" and len(find_urls(self.text)) == 0 {
            name = ingest_text(self.series, self.title, self.text);
            if name != "" {
                added.append(name);
            }
        }
        if len(added) == 0 {
            report {"ok": False, "error": "Nothing usable - give me a URL, or text to pin."};
            disengage;
        }
        loaded = reload_docs(here);
        report {"ok": True, "added": added, "total": len(loaded)};
    }
}


walker:pub ImportOrgDocs {
    """Pull the configured GitHub repo's README + root docs in as grounding
    knowledge - the org-wiki integration, demoed with GitHub."""

    has series: str,
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        visit get_series(self.series);
    }

    can at_series with MeetingSeries entry {
        import os;
        dest = os.path.join(workspace_dir(self.series), "docs");
        saved = fetch_repo_docs(dest);
        if len(saved) == 0 {
            report {"ok": False, "loaded": [],
                    "error": "Nothing fetched - set GITHUB_OWNER/GITHUB_REPO (and GITHUB_PAT for private repos)."};
            disengage;
        }
        loaded = reload_docs(here);
        report {"ok": True, "loaded": saved, "total_docs": len(loaded)};
    }
}


walker:pub LoadDoc {
    """Attach a grounding document to the series, chunked for retrieval."""

    has series: str,
        title: str = "Document",
        text: str = "",
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        visit get_series(self.series);
    }

    can at_series with MeetingSeries entry {
        # Replace only the retrievable corpus - pinned briefings are curated by
        # hand and must survive a doc reload.
        for old in [here -->[?:Doc]] {
            if old.mode != "direct" {
                del old;
            }
        }
        doc = here ++> Doc(title=self.title, mode="rag");
        pieces = chunk_text(self.text);
        for (i, piece) in enumerate(pieces) {
            doc ++> DocChunk(text=piece, idx=i);
        }
        report {"ok": True, "title": self.title, "chunks": len(pieces)};
    }
}
