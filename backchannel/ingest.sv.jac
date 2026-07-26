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
import from workspace { list_workspace_docs, workspace_dir }
import from botctl { bot_running, bot_log_tail }


glob WAKE_PHRASES: list[str] = [
    "hey jac", "hey jack", "hey jak", "hey jacques", "hey check", "a jack"
];

glob CHUNK_CHARS: int = 1000;


"""Deterministic wake-phrase detector.

Returns the ask (everything after the matched phrase) or "" when the line is
not addressed to Backchannel. No model, no network, no cost."""
def detect_wake(text: str) -> str {
    lowered = text.lower();
    for phrase in WAKE_PHRASES {
        if phrase in lowered {
            idx = lowered.index(phrase);
            return text[idx + len(phrase):].strip(" ,.?!:;-");
        }
    }
    return "";
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


"""Split a document into ~CHUNK_CHARS blocks on paragraph boundaries."""
def chunk_text(text: str) -> list[str] {
    chunks: list[str] = [];
    current = "";
    for para in text.split("\n\n") {
        if len(current) + len(para) > CHUNK_CHARS and len(current) > 0 {
            chunks.append(current.strip());
            current = "";
        }
        current = current + para + "\n\n";
    }
    if len(current.strip()) > 0 {
        chunks.append(current.strip());
    }
    return chunks;
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
        ts_ms: int = 0,
        source: str = "replay",
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
        stamp = self.ts_ms;
        if stamp == 0 {
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
        ask = "";
        routed: dict[any] = {};
        if changed and utt is not None {
            ask = detect_wake(utt.text);
            if ask != "" {
                routed = handle_wake(here, ask, utt.seq, utt.text);
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
        chunk_count = 0;
        for d in [here -->[?:Doc]] {
            titles.append(d.title);
            chunk_count += len([d -->[?:DocChunk]]);
        }
        self.memory_cache = memory;
        self.doc_titles = titles;
        self.doc_chunks = chunk_count;
        visit get_live_session(here);
    }

    can at_session with Session entry {
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
            "doc_chunks": self.doc_chunks,
            "bot_running": bot_running(),
            "bot_log": bot_log_tail(2),
            "workspace": workspace_dir(self.series)
        };
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
        found = list_workspace_docs(self.series);
        if len(found) == 0 {
            report {"ok": False, "loaded": [],
                    "error": f"No .md/.txt files in {workspace_dir(self.series)}/docs/"};
            disengage;
        }
        for old in [here -->[?:Doc]] {
            del old;
        }
        loaded: list[str] = [];
        for row in found {
            fname = row[0];
            text = row[1];
            doc = here ++> Doc(title=fname);
            for (i, piece) in enumerate(chunk_text(text)) {
                doc ++> DocChunk(text=piece, idx=i);
            }
            loaded.append(fname);
        }
        report {"ok": True, "loaded": loaded};
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
        for old in [here -->[?:Doc]] {
            del old;
        }
        doc = here ++> Doc(title=self.title);
        pieces = chunk_text(self.text);
        for (i, piece) in enumerate(pieces) {
            doc ++> DocChunk(text=piece, idx=i);
        }
        report {"ok": True, "title": self.title, "chunks": len(pieces)};
    }
}
