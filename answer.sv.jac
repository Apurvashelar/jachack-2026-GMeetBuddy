"""Backchannel - what happens after someone says the wake phrase.

These are the walkers that do the thinking. Each one is spawned ON a Session
node, so `here` is already the meeting it belongs to and the evidence it needs
(transcript, doc, prior sessions) is one or two hops away in the graph. That is
the whole argument for Object-Spatial Programming here: context assembly is
traversal, not a query layer.
"""

import from graph {
    MeetingSeries, Session, Utterance, Answer, Action, Doc, DocChunk,
    SessionSummary, now_ms
}
import from ai {
    SourceKind, Intent, SummaryVerdict, GroundedAnswer,
    safe_answer, safe_route, safe_summary, safe_distill
}
import from adapters { dispatch_action, synthesize_speech, speak_local }
import from workspace { read_context_file, append_context_file }


glob SUMMARY_EVERY: int = 6;
glob TRANSCRIPT_WINDOW: int = 60;

# After Backchannel speaks, its own voice comes back through the room mic and
# Meet captions it. Ignore wake phrases for this long afterwards so the bot
# cannot answer itself. (Headphones also fix it; this makes speakers safe.)
glob ECHO_GUARD_MS: int = 12000;


"""Walk a session's utterances into a plain transcript string."""
def transcript_of(session: Session, limit: int) -> str {
    lines: list[str] = [];
    for u in [session -->[?:Utterance]] {
        lines.append(f"{u.speaker}: {u.text}");
    }
    return "\n".join(lines[-limit:]);
}


"""Retrievable chunks - the RAG corpus, filtered by relevance per question."""
def doc_chunks_of(series: MeetingSeries) -> list[str] {
    chunks: list[str] = [];
    for d in [series -->[?:Doc]] {
        if d.mode == "direct" {
            continue;
        }
        for c in [d -->[?:DocChunk]] {
            chunks.append(c.text);
        }
    }
    return chunks;
}


"""Pinned material, sent verbatim with every answer.

Kept out of the retrieval path on purpose: a glossary or an agenda is short,
always relevant, and must not depend on keyword overlap to be seen."""
def direct_context_of(series: MeetingSeries) -> str {
    blocks: list[str] = [];
    for d in [series -->[?:Doc]] {
        if d.mode != "direct" {
            continue;
        }
        for c in [d -->[?:DocChunk]] {
            blocks.append(f"[{d.title}]\n{c.text}");
        }
    }
    return "\n\n".join(blocks);
}


"""Flatten prior distilled sessions into the memory block.

Two sources, combined: SessionSummary nodes on the graph, and the series'
context.md file - the latter survives even a full graph wipe, and humans can
edit it by hand."""
def prior_memory_of(series: MeetingSeries) -> str {
    blocks: list[str] = [];
    for m in [series -->[?:SessionSummary]] {
        blocks.append(f"[session of {m.started_at}]\n{m.bullets}\nDecisions:\n{m.decisions}");
    }
    file_ctx = read_context_file(series.name);
    if file_ctx.strip() != "" {
        blocks.append(f"[persistent context file]\n{file_ctx}");
    }
    return "\n\n".join(blocks);
}


"""Find the series a session hangs off."""
def series_of(session: Session) -> MeetingSeries | None {
    for s in [session <--[?:MeetingSeries]] {
        return s;
    }
    return None;
}


walker AnswerQuestion {
    """Assemble evidence by traversal, answer with a typed citation, persist it.

    Spawned on the Session node by `IngestChunk` the moment a wake phrase lands.
    """

    has question: str,
        asked_seq: int = 0,
        speak: bool = True,
        reports: list[dict[any]] = [];

    can run with Session entry {
        series = series_of(here);
        chunks: list[str] = [];
        prior = "";
        series_name = "this meeting";
        if series is not None {
            chunks = doc_chunks_of(series);
            prior = prior_memory_of(series);
            series_name = series.name;
        }
        transcript = transcript_of(here, TRANSCRIPT_WINDOW);

        direct = direct_context_of(series) if series is not None else "";
        verdict = safe_answer(self.question, chunks, transcript, prior, direct);

        node_answer = here ++> Answer(
            question=self.question,
            answer=verdict.answer,
            source=verdict.source,
            quote=verdict.quote,
            seq=self.asked_seq,
            ts_ms=now_ms()
        );

        # Voice is best-effort and never blocks the verdict from being persisted.
        if self.speak {
            path = synthesize_speech(verdict.answer, str(node_answer.ts_ms));
            speak_local(path);
        }

        report {
            "kind": "answer", "question": self.question,
            "answer": verdict.answer, "source": verdict.source,
            "quote": verdict.quote, "series": series_name,
            "ts_ms": node_answer.ts_ms
        };
    }
}


walker ExecuteAction {
    """Dispatch a spoken instruction through the org-agent adapter, then keep
    the receipt on the graph so the meeting has a record of what it caused."""

    has payload: str,
        quote: str = "",
        asked_seq: int = 0,
        reports: list[dict[any]] = [];

    can run with Session entry {
        series = series_of(here);
        series_name = series.name if series is not None else "this meeting";

        receipt = dispatch_action(self.payload, series_name, self.quote);

        node_action = here ++> Action(
            kind="github_issue",
            payload=self.payload,
            result_url=receipt.url,
            status=receipt.status,
            detail=receipt.detail,
            seq=self.asked_seq,
            ts_ms=now_ms()
        );

        report {
            "kind": "action", "payload": self.payload,
            "status": receipt.status, "url": receipt.url,
            "detail": receipt.detail, "ts_ms": node_action.ts_ms
        };
    }
}


"""Advance the live summary under the stability contract.

The cadence gate lives on the server so every ingest path gets the same
behaviour, and so a fast-talking meeting cannot melt the API budget: at most one
revision per SUMMARY_EVERY new utterances. Returns the verdict.

This is a plain function rather than a walker on purpose - `Tick` calls it
inline, and a nested walker spawn would push its own `report` into Tick's
response stream and shift the payload the dashboard reads out of `reports[0]`."""
def advance_summary(session: Session, force: bool) -> str {
    pending = session.next_seq - session.summary_seq;
    if pending < SUMMARY_EVERY and not force {
        return "SKIPPED";
    }

    recent: list[str] = [];
    for u in [session -->[?:Utterance]] {
        if u.seq >= session.summary_seq {
            recent.append(f"{u.speaker}: {u.text}");
        }
    }
    if len(recent) == 0 {
        return "SKIPPED";
    }

    update = safe_summary(session.summary, "\n".join(recent));
    session.summary_seq = session.next_seq;
    session.summary_updated_at = float(now_ms());
    if update.verdict == SummaryVerdict.REVISED and update.summary.strip() != "" {
        session.summary = update.summary;
    }
    return update.verdict;
}


walker:pub EndSession {
    """Close the live session and distill it into memory on the series.

    This is what makes the next meeting smarter than this one: the Session node
    stays on the graph, but a SessionSummary is grafted onto the *series*, where
    a future AnswerQuestion will find it as PRIOR_MEETING evidence.
    """

    has series: str,
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        for s in [root -->[?:MeetingSeries]] {
            if s.name == self.series {
                visit s;
            }
        }
    }

    can at_series with MeetingSeries entry {
        closed = 0;
        for sess in [here -->[?:Session]] {
            if not sess.live {
                continue;
            }
            transcript = transcript_of(sess, 400);
            if transcript.strip() != "" {
                distilled = safe_distill(transcript);
                here ++> SessionSummary(
                    bullets=distilled.bullets,
                    decisions=distilled.decisions,
                    started_at=sess.started_at
                );
                # The graph remembers, and so does the workspace file - the
                # file is what makes memory survive even a graph wipe.
                append_context_file(
                    self.series, sess.started_at,
                    distilled.bullets, distilled.decisions
                );
            }
            sess.live = False;
            closed += 1;
        }
        report {"ok": True, "closed": closed, "series": self.series};
    }
}


walker:pub Summarize {
    """Force a summary revision now - the dashboard's Tick cadence hook."""

    has series: str,
        force: bool = False,
        reports: list[dict[any]] = [];

    can at_root with Root entry {
        for s in [root -->[?:MeetingSeries]] {
            if s.name == self.series {
                visit s;
            }
        }
    }

    can at_series with MeetingSeries entry {
        for sess in [here -->[?:Session]] {
            if sess.live {
                visit sess;
            }
        }
    }

    can at_session with Session entry {
        verdict = advance_summary(here, self.force);
        report {"kind": "summary", "verdict": verdict, "summary": here.summary};
    }
}


"""Route one wake-phrase ask and run it. Called from the ingest inlet, which is
why the trigger path costs nothing until a human actually says the phrase."""
def handle_wake(session: Session, ask: str, seq: int, said: str,
                same_breath: bool = False) -> dict[any] {
    if ask.strip() == "" {
        return {"kind": "ignored", "reason": "empty ask"};
    }
    # The echo guard stops the bot answering its own spoken reply after the
    # room mic picks it up. It must NOT stop a human who asked three questions
    # in one breath - those all arrive inside a single caption block, so
    # `same_breath` waives the guard for the second and later asks in it.
    if not same_breath and now_ms() - session.last_answer_ms < ECHO_GUARD_MS {
        return {"kind": "ignored", "reason": "echo guard - bot just spoke"};
    }

    routed = safe_route(ask);

    if routed.intent == Intent.IGNORE {
        return {"kind": "ignored", "reason": "router classified as false trigger"};
    }

    payload = routed.payload if routed.payload.strip() != "" else ask;

    if routed.intent == Intent.ACTION {
        session.last_answer_ms = now_ms();
        session spawn ExecuteAction(payload=payload, quote=said, asked_seq=seq);
        return {"kind": "action", "payload": payload};
    }

    session.last_answer_ms = now_ms();
    session spawn AnswerQuestion(question=payload, asked_seq=seq);
    return {"kind": "answer", "question": payload};
}
