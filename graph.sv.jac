"""Backchannel - the graph IS the meeting.

Every archetype here is root-reachable, so Jac's graph-native persistence keeps
the whole meeting memory alive across server restarts with no database at all.

    root --> MeetingSeries --> Session --> Utterance
                           --> SessionSummary        (distilled cross-meeting memory)
                           --> Doc --> DocChunk      (the grounding document)
             Session --> Answer                      (persisted, cited verdicts)
             Session --> Action                      (org-agent receipts)
"""

import time;
import from datetime { datetime }


node MeetingSeries {
    """A recurring meeting. The anchor for memory that outlives one session."""

    has name: str;
}


node Session {
    """One capture run - a single sitting of the series."""

    has started_at: str = "",
        source: str = "replay",
        live: bool = True,
        summary: str = "",
        summary_seq: int = 0,
        summary_updated_at: float = 0.0,
        last_answer_ms: int = 0,
        next_seq: int = 0;
}


node Utterance {
    """One caption line. Upserted by `caption_id`, newest `version` wins."""

    has speaker: str,
        text: str,
        caption_id: str = "",
        version: int = 0,
        seq: int = 0,
        ts_ms: int = 0,
        wake_done: bool = False;
}


node Answer {
    """A grounded verdict, with the typed citation that produced it."""

    has question: str,
        answer: str,
        source: str = "UNKNOWN",
        quote: str = "",
        seq: int = 0,
        ts_ms: int = 0;
}


node Action {
    """A receipt for something Backchannel did in the outside world."""

    has kind: str,
        payload: str,
        result_url: str = "",
        status: str = "pending",
        detail: str = "",
        seq: int = 0,
        ts_ms: int = 0;
}


node SessionSummary {
    """Distilled memory of a finished session, attached to the series."""

    has bullets: str = "",
        decisions: str = "",
        started_at: str = "";
}


node BotRequest {
    """A queued "go join this meeting" instruction.

    A hosted brain has no display, so it cannot run a headed Chromium itself.
    Instead it parks the request here and a local ears agent - running on a
    laptop that DOES have a screen - claims it and does the joining. The brain
    stays wherever it is deployed; only the browser has to be near a human.
    """

    has series: str,
        meet_url: str,
        status: str = "pending",
        created_at: int = 0,
        claimed_at: int = 0;
}


node Doc {
    """A grounding document for a series.

    `mode` decides how it reaches the model:
      "rag"    - chunked and retrieved by relevance. For big corpora: papers,
                 wikis, specs. Only the matching pieces are sent.
      "direct" - injected verbatim into every answer. For the short, always-
                 relevant things: the agenda, a glossary, "we are the payments
                 team and X means Y here". Never filtered out by a bad keyword
                 match, which is exactly why it exists.
    """

    has title: str,
        mode: str = "rag";
}


node DocChunk {
    has text: str,
        idx: int = 0;
}


"""Milliseconds since the epoch, as an int."""
def now_ms -> int {
    return int(time.time() * 1000);
}


"""Human-readable wall clock for session labels."""
def now_iso -> str {
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S");
}


"""Get-or-create the series. Without the filter-first check every request
would graft a duplicate series onto root."""
def get_series(series_name: str) -> MeetingSeries {
    for s in [root -->[?:MeetingSeries]] {
        if s.name == series_name {
            return s;
        }
    }
    return root ++> MeetingSeries(name=series_name);
}


"""Get-or-create the one open session hanging off this series."""
def get_live_session(series: MeetingSeries) -> Session {
    for sess in [series -->[?:Session]] {
        if sess.live {
            return sess;
        }
    }
    return series ++> Session(started_at=now_iso(), live=True);
}
