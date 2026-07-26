"""Backchannel dashboard - one Jac file, compiled to React.

Polling is a `root spawn Tick(...)` rather than an `sv import` reader call on
purpose: reader responses are cached for 60 seconds, which would freeze a feed
whose entire job is being live.

Two React traps this file is written around:
  - Stale closures. The interval callback would capture an old cursor forever,
    so `Tick` is always asked for the whole session (`after_seq = -1`) and the
    feed list is replaced, not appended.
  - In-place mutation. Every list update REBINDS (`xs = xs + [x]`); calling
    `.append` would mutate without re-rendering.
"""

import from react { useEffect }

import from .components.Cards { AnswerCard, ActionCard, FeedLine, SourceBadge }

sv import from ingest { Tick }
sv import from answer { EndSession, Summarize }


glob SERIES_NAME: str = "Research Weekly Sync";

# Module-level, deliberately: a `has` field read inside the polling interval
# would be a stale closure, and we only need "have I already said this out loud".
glob spokenAnswers: list[str] = [];

# jac2js emits a literal backslash-n for "\n" in client code; chr(10) is the
# portable spelling (see `jac guide jac-cl-js-interop`).
glob _NL: str = chr(10);


"""Speak an answer through the browser's own speech synthesis.

This is the baseline voice and it has no external dependency - the OpenAI TTS
path in `adapters.sv.jac` is an upgrade on top of it, not a prerequisite."""
def speakAnswer(text: str) -> None {
    # `jac check` has no typed stubs for browser globals, so these lines are
    # flagged despite being correct at runtime (see `jac guide jac-cl-js-interop`).
    utterance: any = new(SpeechSynthesisUtterance, text);  # jac:ignore[E1053]
    utterance.rate = 1.02;
    utterance.pitch = 1.0;
    window.speechSynthesis.speak(utterance);  # jac:ignore[E1030]
}


def:pub app -> JsxElement {
    has utterances: list[any] = [],
        answers: list[any] = [],
        actions: list[any] = [],
        memory: list[any] = [],
        summary: str = "",
        docTitle: str = "",
        docChunks: int = 0,
        startedAt: str = "",
        source: str = "",
        total: int = 0,
        live: bool = True,
        voiceOn: bool = True,
        connected: bool = False,
        busy: bool = False;

    async def poll -> None {
        try {
            result = root spawn Tick(series=SERIES_NAME, after_seq=-1);
            if not result.reports or len(result.reports) == 0 {
                return;
            }
            r: any = result.reports[0];
            connected = True;
            utterances = r["utterances"] as list[any];
            answers = r["answers"] as list[any];
            actions = r["actions"] as list[any];
            memory = r["memory"] as list[any];
            summary = str(r["summary"]);
            docTitle = str(r["doc_title"]);
            docChunks = int(r["doc_chunks"]);
            startedAt = str(r["started_at"]);
            source = str(r["source"]);
            total = int(r["total"]);
            live = bool(r["live"]);

            for a in (r["answers"] as list[any]) {
                key = str(a["ts_ms"]);
                if key not in spokenAnswers {
                    spokenAnswers = spokenAnswers + [key];
                    # Only speak answers that arrive while the page is open, so
                    # reloading mid-demo does not replay the whole meeting.
                    if voiceOn and len(spokenAnswers) > 0 and connected {
                        speakAnswer(str(a["answer"]));
                    }
                }
            }
        } except Exception as e {
            connected = False;
        }
    }

    async def forceSummary(e: MouseEvent) -> None {
        busy = True;
        root spawn Summarize(series=SERIES_NAME, force=True);
        busy = False;
    }

    async def endSession(e: MouseEvent) -> None {
        busy = True;
        root spawn EndSession(series=SERIES_NAME);
        busy = False;
    }

    def toggleVoice(e: MouseEvent) -> None {
        voiceOn = not voiceOn;
    }

    useEffect(lambda {
        poll();
        interval = setInterval(lambda { poll(); }, 2000);
        return lambda { clearInterval(interval); };
    }, []);

    return <div
        style={{
            "minHeight": "100vh", "backgroundColor": "#0d1017",
            "color": "#f2f5fa", "fontFamily": "ui-sans-serif, system-ui, -apple-system, sans-serif",
            "padding": "1.5rem"
        }}
    >
        <header style={{"maxWidth": "1180px", "margin": "0 auto 1.25rem"}}>
            <div style={{"display": "flex", "alignItems": "baseline", "gap": "0.75rem", "flexWrap": "wrap"}}>
                <h1 style={{"margin": "0", "fontSize": "1.6rem", "letterSpacing": "-0.02em"}}>Backchannel</h1>
                <span style={{"color": "#6f7891", "fontSize": "0.85rem"}}>the meeting is the graph</span>
                <span style={{"flex": "1"}}></span>
                <span
                    style={{
                        "fontSize": "0.7rem", "letterSpacing": "0.08em", "fontWeight": "700",
                        "color": "#33c46f" if connected else "#ff5d5d"
                    }}
                >{"● BRAIN CONNECTED" if connected else "● BRAIN OFFLINE"}</span>
            </div>
            <div style={{"marginTop": "0.5rem", "color": "#7f8798", "fontSize": "0.8rem", "display": "flex", "gap": "1.25rem", "flexWrap": "wrap"}}>
                <span>series <strong style={{"color": "#c9d1e0"}}>{SERIES_NAME}</strong></span>
                <span>session <strong style={{"color": "#c9d1e0"}}>{startedAt if startedAt != "" else "—"}</strong></span>
                <span>ears <strong style={{"color": "#c9d1e0"}}>{source if source != "" else "—"}</strong></span>
                <span>captions <strong style={{"color": "#c9d1e0"}}>{str(total)}</strong></span>
                <span>doc <strong style={{"color": "#c9d1e0"}}>{(docTitle[:44] + " · " + str(docChunks) + " chunks") if docTitle != "" else "none loaded"}</strong></span>
            </div>
        </header>

        <div
            style={{
                "maxWidth": "1180px", "margin": "0 auto", "display": "grid",
                "gridTemplateColumns": "minmax(300px, 1.1fr) minmax(320px, 1fr)",
                "gap": "1rem", "alignItems": "start"
            }}
        >
            <section
                style={{
                    "backgroundColor": "#11151d", "border": "1px solid #1e2430",
                    "borderRadius": "14px", "padding": "1rem"
                }}
            >
                <div style={{"display": "flex", "justifyContent": "space-between", "alignItems": "center", "marginBottom": "0.6rem"}}>
                    <h2 style={{"margin": "0", "fontSize": "0.78rem", "letterSpacing": "0.1em", "color": "#8b93a7"}}>LIVE TRANSCRIPT</h2>
                    <span style={{"fontSize": "0.68rem", "color": "#33c46f" if live else "#6f7891"}}>{"● LIVE" if live else "SESSION CLOSED"}</span>
                </div>
                <div style={{"maxHeight": "62vh", "overflowY": "auto"}}>
                    {if len(utterances) == 0 {
                        <p style={{"color": "#5c6479", "fontSize": "0.85rem"}}>
                            Waiting for captions. Start the replay, or admit the bot into a Meet.
                        </p>
                    }}
                    {for u in utterances {
                        <FeedLine
                            key={str(u["seq"])}
                            speaker={u["speaker"]}
                            text={u["text"]}
                            isWake={"hey jac" in str(u["text"]).lower()}
                        />
                    }}
                </div>
            </section>

            <div style={{"display": "flex", "flexDirection": "column", "gap": "1rem"}}>
                <section
                    style={{
                        "backgroundColor": "#11151d", "border": "1px solid #1e2430",
                        "borderRadius": "14px", "padding": "1rem"
                    }}
                >
                    <div style={{"display": "flex", "justifyContent": "space-between", "alignItems": "center", "marginBottom": "0.5rem", "gap": "0.5rem"}}>
                        <h2 style={{"margin": "0", "fontSize": "0.78rem", "letterSpacing": "0.1em", "color": "#8b93a7"}}>ROLLING SUMMARY</h2>
                        <div style={{"display": "flex", "gap": "0.4rem"}}>
                            <button
                                onClick={toggleVoice}
                                style={{
                                    "background": "transparent", "border": "1px solid #2b3243",
                                    "color": "#33c46f" if voiceOn else "#6f7891", "borderRadius": "7px",
                                    "padding": "0.25rem 0.55rem", "fontSize": "0.68rem", "cursor": "pointer"
                                }}
                            >{"VOICE ON" if voiceOn else "VOICE OFF"}</button>
                            <button
                                onClick={forceSummary}
                                style={{
                                    "background": "transparent", "border": "1px solid #2b3243",
                                    "color": "#8b93a7", "borderRadius": "7px",
                                    "padding": "0.25rem 0.55rem", "fontSize": "0.68rem", "cursor": "pointer"
                                }}
                            >SUMMARIZE NOW</button>
                            <button
                                onClick={endSession}
                                style={{
                                    "background": "transparent", "border": "1px solid #2b3243",
                                    "color": "#a274ff", "borderRadius": "7px",
                                    "padding": "0.25rem 0.55rem", "fontSize": "0.68rem", "cursor": "pointer"
                                }}
                            >END + DISTILL</button>
                        </div>
                    </div>
                    {if summary.strip() == "" {
                        <p style={{"color": "#5c6479", "fontSize": "0.85rem", "margin": "0"}}>
                            No summary yet. It revises only on a new finding, a status change, or a correction — never on rewording.
                        </p>
                    }}
                    {if summary.strip() != "" {
                        <pre
                            style={{
                                "margin": "0", "whiteSpace": "pre-wrap", "fontFamily": "inherit",
                                "color": "#dfe5ef", "fontSize": "0.86rem", "lineHeight": "1.6"
                            }}
                        >{summary}</pre>
                    }}
                </section>

                <section
                    style={{
                        "backgroundColor": "#11151d", "border": "1px solid #1e2430",
                        "borderRadius": "14px", "padding": "1rem"
                    }}
                >
                    <h2 style={{"margin": "0 0 0.6rem", "fontSize": "0.78rem", "letterSpacing": "0.1em", "color": "#8b93a7"}}>ANSWERS &amp; ACTIONS</h2>
                    <div style={{"maxHeight": "42vh", "overflowY": "auto"}}>
                        {if len(answers) == 0 and len(actions) == 0 {
                            <p style={{"color": "#5c6479", "fontSize": "0.85rem"}}>
                                Say “Hey Jac, …” in the meeting. Every answer arrives with a typed source citation.
                            </p>
                        }}
                        {for a in answers {
                            <AnswerCard
                                key={str(a["ts_ms"])}
                                question={a["question"]}
                                answer={a["answer"]}
                                source={a["source"]}
                                quote={a["quote"]}
                            />
                        }}
                        {for a in actions {
                            <ActionCard
                                key={str(a["ts_ms"])}
                                payload={a["payload"]}
                                status={a["status"]}
                                url={a["result_url"]}
                                detail={a["detail"]}
                            />
                        }}
                    </div>
                </section>

                {if len(memory) > 0 {
                    <section
                        style={{
                            "backgroundColor": "#11151d", "border": "1px solid #2a2140",
                            "borderRadius": "14px", "padding": "1rem"
                        }}
                    >
                        <div style={{"display": "flex", "justifyContent": "space-between", "alignItems": "center", "marginBottom": "0.6rem"}}>
                            <h2 style={{"margin": "0", "fontSize": "0.78rem", "letterSpacing": "0.1em", "color": "#a274ff"}}>CROSS-MEETING MEMORY</h2>
                            <SourceBadge source="PRIOR_MEETING"/>
                        </div>
                        {for m in memory {
                            <div key={m["started_at"]} style={{"marginBottom": "0.7rem"}}>
                                <div style={{"color": "#6f7891", "fontSize": "0.7rem", "marginBottom": "0.25rem"}}>session of {m["started_at"]}</div>
                                <pre
                                    style={{
                                        "margin": "0", "whiteSpace": "pre-wrap", "fontFamily": "inherit",
                                        "color": "#c9d1e0", "fontSize": "0.82rem", "lineHeight": "1.55"
                                    }}
                                >{m["bullets"]}</pre>
                                {if str(m["decisions"]).strip() != "" {
                                    <pre
                                        style={{
                                            "margin": "0.4rem 0 0", "whiteSpace": "pre-wrap", "fontFamily": "inherit",
                                            "color": "#8b93a7", "fontSize": "0.78rem", "lineHeight": "1.5"
                                        }}
                                    >{"decisions:" + _NL + str(m["decisions"])}</pre>
                                }}
                            </div>
                        }}
                    </section>
                }}
            </div>
        </div>

        <footer style={{"maxWidth": "1180px", "margin": "1.25rem auto 0", "color": "#4e5568", "fontSize": "0.72rem"}}>
            Self-hosted end to end · captions never transit a third party · the trigger path makes zero model calls
        </footer>
    </div>;
}
