"""Backchannel console - one Jac file, compiled to React.

Polling is a `root spawn Tick(...)` rather than an `sv import` reader call on
purpose: reader responses are cached for 60 seconds, which would freeze a feed
whose entire job is being live.

Two React traps this file is written around:
  - Stale closures. The interval callback would capture an old cursor forever,
    so `Tick` is always asked for the whole session and the feed is replaced,
    not appended.
  - In-place mutation. Every list update REBINDS; `.append` would mutate
    without re-rendering.
"""

import from react { useEffect }

import from .components.Cards { AnswerCard, ActionCard, FeedLine, SourceChip }

sv import from ingest { Tick, SyncWorkspace, ImportOrgDocs, AddSource }
sv import from answer { EndSession, Summarize }
sv import from botctl { StartBot, StopBot }


glob SERIES_NAME: str = "Research Weekly Sync";

# Module-level, deliberately: a `has` field read inside the polling interval
# would be a stale closure, and we only need "have I already said this aloud".
glob spokenAnswers: list[str] = [];

# jac2js emits a literal backslash-n for "\n" in client code; chr(10) is the
# portable spelling (see `jac guide jac-cl-js-interop`).
glob _NL: str = chr(10);


"""Speak an answer through the browser's own speech synthesis.

The baseline voice, with no external dependency - the OpenAI tts-1 path in
`adapters.sv.jac` is an upgrade on top of it, not a prerequisite."""
def speakAnswer(text: str) -> None {
    # `jac check` has no typed stubs for browser globals, so these lines are
    # flagged despite being correct at runtime (see `jac guide jac-cl-js-interop`).
    utterance: any = new(SpeechSynthesisUtterance, text);  # jac:ignore[E1053]
    utterance.rate = 1.02;
    window.speechSynthesis.speak(utterance);  # jac:ignore[E1030]
}


def:pub app -> JsxElement {
    has utterances: list[any] = [],
        answers: list[any] = [],
        actions: list[any] = [],
        memory: list[any] = [],
        summary: str = "",
        docTitles: list[any] = [],
        docChunks: int = 0,
        startedAt: str = "",
        source: str = "",
        total: int = 0,
        live: bool = True,
        voiceOn: bool = True,
        connected: bool = False,
        meetUrl: str = "",
        botRunning: bool = False,
        botLog: str = "",
        botMsg: str = "",
        syncMsg: str = "",
        pinnedTitles: list[any] = [],
        ragUrl: str = "",
        pinText: str = "";

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
            docTitles = r["doc_titles"] as list[any];
            pinnedTitles = r["pinned_titles"] as list[any];
            docChunks = int(r["doc_chunks"]);
            startedAt = str(r["started_at"]);
            source = str(r["source"]);
            total = int(r["total"]);
            live = bool(r["live"]);
            botRunning = bool(r["bot_running"]);
            botLog = str(r["bot_log"]);

            for a in (r["answers"] as list[any]) {
                key = str(a["ts_ms"]);
                if key not in spokenAnswers {
                    spokenAnswers = spokenAnswers + [key];
                    if voiceOn and connected {
                        speakAnswer(str(a["answer"]));
                    }
                }
            }
        } except Exception as e {
            connected = False;
        }
    }

    async def sendBot(e: MouseEvent) -> None {
        if meetUrl.strip() == "" {
            botMsg = "Paste a Google Meet link first.";
            return;
        }
        botMsg = "Launching...";
        result = root spawn StartBot(series=SERIES_NAME, meet_url=meetUrl);
        if result.reports and len(result.reports) > 0 {
            r: any = result.reports[0];
            botMsg = str(r["note"]) if bool(r["ok"]) else str(r["error"]);
        }
    }

    async def stopTheBot(e: MouseEvent) -> None {
        result = root spawn StopBot();
        if result.reports and len(result.reports) > 0 {
            r: any = result.reports[0];
            botMsg = "Bot stopped." if bool(r["ok"]) else str(r["error"]);
        }
    }

    async def syncDocs(e: MouseEvent) -> None {
        syncMsg = "Syncing...";
        result = root spawn SyncWorkspace(series=SERIES_NAME);
        if result.reports and len(result.reports) > 0 {
            r: any = result.reports[0];
            if bool(r["ok"]) {
                syncMsg = "Loaded " + str(len(r["loaded"] as list[any])) + " source(s)";
            } else {
                syncMsg = str(r["error"]);
            }
        }
    }

    async def importOrgDocs(e: MouseEvent) -> None {
        syncMsg = "Importing from the repo...";
        result = root spawn ImportOrgDocs(series=SERIES_NAME);
        if result.reports and len(result.reports) > 0 {
            r: any = result.reports[0];
            if bool(r["ok"]) {
                syncMsg = "Imported " + str(len(r["loaded"] as list[any])) + " repo doc(s)";
            } else {
                syncMsg = str(r["error"]);
            }
        }
    }

    async def addRagSource(e: MouseEvent) -> None {
        if ragUrl.strip() == "" {
            syncMsg = "Paste a URL to add searchable knowledge.";
            return;
        }
        syncMsg = "Fetching and indexing...";
        result = root spawn AddSource(series=SERIES_NAME, mode="rag", url=ragUrl);
        if result.reports and len(result.reports) > 0 {
            r: any = result.reports[0];
            if bool(r["ok"]) {
                syncMsg = "Indexed " + str(len(r["added"] as list[any])) + " source(s)";
                ragUrl = "";
            } else {
                syncMsg = str(r["error"]);
            }
        }
    }

    async def addPinned(e: MouseEvent) -> None {
        if pinText.strip() == "" {
            syncMsg = "Type the context you want in every answer.";
            return;
        }
        syncMsg = "Pinning...";
        result = root spawn AddSource(series=SERIES_NAME, mode="direct", text=pinText, title="briefing");
        if result.reports and len(result.reports) > 0 {
            r: any = result.reports[0];
            if bool(r["ok"]) {
                syncMsg = "Pinned - now sent with every answer";
                pinText = "";
            } else {
                syncMsg = str(r["error"]);
            }
        }
    }

    async def forceSummary(e: MouseEvent) -> None {
        root spawn Summarize(series=SERIES_NAME, force=True);
    }

    async def endSession(e: MouseEvent) -> None {
        root spawn EndSession(series=SERIES_NAME);
    }

    def toggleVoice(e: MouseEvent) -> None {
        voiceOn = not voiceOn;
    }

    useEffect(lambda {
        poll();
        interval = setInterval(lambda { poll(); }, 2000);
        return lambda { clearInterval(interval); };
    }, []);

    return <div className="bc-shell">
        <header className="bc-rail">
            <h1 className="bc-wordmark">Backchannel<span>talkback</span></h1>
            <span className={"bc-onair is-live" if live and connected else "bc-onair is-off"}>
                <span className="bc-dot"></span>
                {"on air" if live and connected else ("standby" if connected else "no signal")}
            </span>
            <span className="bc-rail-spacer"></span>
            <dl className="bc-stats">
                <div className="bc-stat"><dt>meeting</dt><dd>{SERIES_NAME}</dd></div>
                <div className="bc-stat"><dt>captions</dt><dd>{str(total)}</dd></div>
                <div className="bc-stat"><dt>searchable</dt><dd>{str(len(docTitles)) + " · " + str(docChunks) + " chunks"}</dd></div>
                <div className="bc-stat"><dt>pinned</dt><dd>{str(len(pinnedTitles))}</dd></div>
                <div className="bc-stat"><dt>memory</dt><dd>{str(len(memory)) + " prior"}</dd></div>
                <div className="bc-stat"><dt>ears</dt><dd>{source if source != "" else "idle"}</dd></div>
            </dl>
        </header>

        <main className="bc-body">
            <section className="bc-module">
                <div className="bc-module-head">
                    <h2>program feed</h2>
                    <span className="bc-rail-spacer"></span>
                    <span className="bc-time">{startedAt if startedAt != "" else "no session"}</span>
                </div>
                <div className="bc-module-body bc-scroll bc-feed-scroll">
                    {if len(utterances) == 0 {
                        <p className="bc-empty">
                            Nothing on the wire yet. Send the bot into a meeting, or run <code>jac run replay.jac</code> to feed it a scripted one.
                        </p>
                    }}
                    {for u in utterances {
                        <FeedLine
                            key={str(u["seq"])}
                            speaker={str(u["speaker"])}
                            text={str(u["text"])}
                            isCue={"hey jac" in str(u["text"]).lower()}
                            tsMs={int(u["ts_ms"])}
                        />
                    }}
                </div>
            </section>

            <div className="bc-col">
                <section className="bc-module">
                    <div className="bc-module-head">
                        <h2>meeting control</h2>
                        <span className="bc-rail-spacer"></span>
                        <span className={"bc-onair is-live" if botRunning else "bc-onair is-off"}>
                            <span className="bc-dot"></span>{"bot in call" if botRunning else "bot idle"}
                        </span>
                    </div>
                    <div className="bc-module-body">
                        <div className="bc-controls">
                            <input
                                className="bc-input"
                                type="text"
                                value={meetUrl}
                                onChange={lambda (e: ChangeEvent) { meetUrl = e.target.value; }}
                                placeholder="meet.google.com/xxx-xxxx-xxx"
                            />
                            {if not botRunning {
                                <button className="bc-btn is-primary" onClick={sendBot}>send bot</button>
                            }}
                            {if botRunning {
                                <button className="bc-btn is-danger" onClick={stopTheBot}>stop bot</button>
                            }}
                        </div>
                        {if botMsg != "" {
                            <p className="bc-note">{botMsg}</p>
                        }}
                        {if botRunning and botLog != "" {
                            <pre className="bc-log">{botLog}</pre>
                        }}
                        <div className="bc-sources">
                            <span className="bc-source-list">
                                {(", ".join([str(t) for t in docTitles])) if len(docTitles) > 0 else "no sources loaded"}
                            </span>
                            <button className="bc-btn" onClick={syncDocs}>sync folder</button>
                            <button className="bc-btn" onClick={importOrgDocs}>import repo</button>
                        </div>
                        {if syncMsg != "" {
                            <p className="bc-note">{syncMsg}</p>
                        }}
                    </div>
                </section>

                <section className="bc-module">
                    <div className="bc-module-head">
                        <h2>standing summary</h2>
                        <span className="bc-rail-spacer"></span>
                        <button className={"bc-btn is-on" if voiceOn else "bc-btn"} onClick={toggleVoice}>{"voice on" if voiceOn else "voice off"}</button>
                        <button className="bc-btn" onClick={forceSummary}>revise</button>
                        <button className="bc-btn" onClick={endSession}>close + distill</button>
                    </div>
                    <div className="bc-module-body">
                        {if summary.strip() == "" {
                            <p className="bc-empty">
                                Holding. The summary revises only on a new finding, a status change, or a correction — never on rewording.
                            </p>
                        }}
                        {if summary.strip() != "" {
                            <pre className="bc-summary">{summary}</pre>
                        }}
                    </div>
                </section>

                <section className="bc-module">
                    <div className="bc-module-head">
                        <h2>verdicts</h2>
                        <span className="bc-rail-spacer"></span>
                        <span className="bc-time">{str(len(answers)) + " answered · " + str(len(actions)) + " acted"}</span>
                    </div>
                    <div className="bc-module-body bc-scroll bc-verdict-scroll">
                        {if len(answers) == 0 and len(actions) == 0 {
                            <p className="bc-empty">
                                Say <code>Hey Jac, …</code> in the meeting. Every answer arrives with the source it came from.
                            </p>
                        }}
                        {for a in actions {
                            <ActionCard
                                key={str(a["ts_ms"])}
                                payload={str(a["payload"])}
                                status={str(a["status"])}
                                url={str(a["result_url"])}
                                detail={str(a["detail"])}
                            />
                        }}
                        {for a in answers {
                            <AnswerCard
                                key={str(a["ts_ms"])}
                                question={str(a["question"])}
                                answer={str(a["answer"])}
                                source={str(a["source"])}
                                quote={str(a["quote"])}
                            />
                        }}
                    </div>
                </section>

                {if len(memory) > 0 {
                    <section className="bc-module">
                        <div className="bc-module-head">
                            <h2>carried forward</h2>
                            <span className="bc-rail-spacer"></span>
                            <SourceChip source="PRIOR_MEETING"/>
                        </div>
                        <div className="bc-module-body">
                            {for m in memory {
                                <div className="bc-memory-block" key={str(m["started_at"])}>
                                    <div className="bc-memory-when">{str(m["started_at"])}</div>
                                    <pre className="bc-memory-text">{str(m["bullets"])}</pre>
                                    {if str(m["decisions"]).strip() != "" {
                                        <pre className="bc-memory-text">{"decisions:" + _NL + str(m["decisions"])}</pre>
                                    }}
                                </div>
                            }}
                        </div>
                    </section>
                }}
            </div>
        </main>

        <footer className="bc-foot">
            self-hosted end to end · captions never transit a third party · the trigger path makes zero model calls
        </footer>
    </div>;
}
