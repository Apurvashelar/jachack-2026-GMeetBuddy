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

import from .components.Cards { AnswerCard, ActionCard, FeedLine, SourceChip, DropTile }

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

# 28 bars: enough to read as signal, few enough to stay cheap to animate.
glob WAVE_BARS: list[int] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
    14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27
];


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
        pinnedTitles: list[any] = [],
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
        ragUrl: str = "",
        pinUrl: str = "",
        pinText: str = "",
        overTile: str = "";

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

    """Send one source to the brain and report what happened."""
    async def submitSource(mode: str, url: str, text: str) -> None {
        result = root spawn AddSource(series=SERIES_NAME, mode=mode, url=url, text=text, title="briefing");
        if result.reports and len(result.reports) > 0 {
            r: any = result.reports[0];
            if bool(r["ok"]) {
                syncMsg = ("Indexed " if mode == "rag" else "Pinned ") + str(len(r["added"] as list[any])) + " source(s)";
            } else {
                syncMsg = str(r["error"]);
            }
        }
    }

    """Read a browser File and hand it over as base64.

    FileReader is callback-based, so this wraps it in a Promise the async
    handler below can await - otherwise the upload fires before the bytes
    have been read."""
    def readFile(file: any) -> any {
        return new(Promise, lambda (resolve: any, reject: any) {
            reader: any = new(FileReader);  # jac:ignore[E1053]
            reader.onload = lambda (e: any) {
                # dataURL looks like "data:<mime>;base64,<payload>"
                raw = String(reader.result);
                resolve.call(None, raw.split(",")[1]);
            };
            reader.onerror = lambda (e: any) { resolve.call(None, ""); };
            reader.readAsDataURL(file);
        });
    }

    async def uploadFiles(mode: str, files: any) -> None {
        count = int(files.length);
        if count == 0 {
            return;
        }
        syncMsg = "Reading " + str(count) + " file(s)...";
        ok = 0;
        skipped = 0;
        for i in range(count) {
            f: any = files[i];
            name = String(f.name);
            lower = name.lower();
            if not (lower.endswith(".pdf") or lower.endswith(".md") or lower.endswith(".txt") or lower.endswith(".markdown")) {
                skipped += 1;
                continue;
            }
            b64 = await readFile(f);
            if not b64 {
                skipped += 1;
                continue;
            }
            result = root spawn AddSource(
                series=SERIES_NAME, mode=mode, filename=name, content_b64=b64
            );
            if result.reports and len(result.reports) > 0 {
                r: any = result.reports[0];
                if bool(r["ok"]) { ok += 1; } else { skipped += 1; }
            }
        }
        tail = (", " + str(skipped) + " skipped") if skipped > 0 else "";
        syncMsg = ("Indexed " if mode == "rag" else "Pinned ") + str(ok) + " file(s)" + tail;
    }

    async def addRagUrl(e: MouseEvent) -> None {
        if ragUrl.strip() == "" { syncMsg = "Paste a URL to index."; return; }
        syncMsg = "Fetching and indexing...";
        await submitSource("rag", ragUrl, "");
        ragUrl = "";
    }

    async def addPinUrl(e: MouseEvent) -> None {
        if pinUrl.strip() == "" { syncMsg = "Paste a URL to pin."; return; }
        syncMsg = "Fetching and pinning...";
        await submitSource("direct", pinUrl, "");
        pinUrl = "";
    }

    async def addPinText(e: MouseEvent) -> None {
        if pinText.strip() == "" { syncMsg = "Type the context you want in every answer."; return; }
        syncMsg = "Pinning...";
        await submitSource("direct", "", pinText);
        pinText = "";
    }

    async def onRagFiles(e: ChangeEvent) -> None { await uploadFiles("rag", e.target.files); }
    async def onPinFiles(e: ChangeEvent) -> None { await uploadFiles("direct", e.target.files); }

    def dragOver(tile: str, e: any) -> None {
        e.preventDefault();
        overTile = tile;
    }

    def dragLeave(e: any) -> None { overTile = ""; }

    async def dropOn(mode: str, e: any) -> None {
        e.preventDefault();
        overTile = "";
        await uploadFiles(mode, e.dataTransfer.files);
    }

    async def sendBot(e: MouseEvent) -> None {
        if meetUrl.strip() == "" { botMsg = "Paste a Google Meet link first."; return; }
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
        syncMsg = "Rescanning the workspace folder...";
        result = root spawn SyncWorkspace(series=SERIES_NAME);
        if result.reports and len(result.reports) > 0 {
            r: any = result.reports[0];
            syncMsg = ("Loaded " + str(len(r["loaded"] as list[any])) + " source(s)") if bool(r["ok"]) else str(r["error"]);
        }
    }

    async def importOrgDocs(e: MouseEvent) -> None {
        syncMsg = "Importing from the repo...";
        result = root spawn ImportOrgDocs(series=SERIES_NAME);
        if result.reports and len(result.reports) > 0 {
            r: any = result.reports[0];
            syncMsg = ("Imported " + str(len(r["loaded"] as list[any])) + " repo doc(s)") if bool(r["ok"]) else str(r["error"]);
        }
    }

    async def forceSummary(e: MouseEvent) -> None { root spawn Summarize(series=SERIES_NAME, force=True); }
    async def endSession(e: MouseEvent) -> None { root spawn EndSession(series=SERIES_NAME); }
    def toggleVoice(e: MouseEvent) -> None { voiceOn = not voiceOn; }

    useEffect(lambda {
        poll();
        interval = setInterval(lambda { poll(); }, 2000);
        return lambda { clearInterval(interval); };
    }, []);

    hearing = connected and live;

    return <div className="bc-shell">
        <header className="bc-hero">
            <div className="bc-mark">
                <div className="bc-mark-glyph">B</div>
                <div className="bc-mark-text">
                    <h1>Backchannel</h1>
                    <p>{SERIES_NAME}</p>
                </div>
            </div>

            <div className={"bc-wave is-live" if hearing else "bc-wave"}>
                {for i in WAVE_BARS {
                    <i key={str(i)} style={{"animationDelay": str(i * 0.055) + "s"}}></i>
                }}
            </div>

            <span className={"bc-status is-live" if hearing else "bc-status is-off"}>
                <b></b>{"listening" if hearing else ("standby" if connected else "no signal")}
            </span>
        </header>

        <dl className="bc-ribbon">
            <div className="bc-tile"><dt>captions</dt><dd>{str(total)}</dd></div>
            <div className="bc-tile is-mint"><dt>answered</dt><dd>{str(len(answers))}</dd></div>
            <div className="bc-tile"><dt>searchable</dt><dd>{str(len(docTitles))} <small>{"· " + str(docChunks) + " chunks"}</small></dd></div>
            <div className="bc-tile is-accent"><dt>pinned</dt><dd>{str(len(pinnedTitles))}</dd></div>
            <div className="bc-tile"><dt>memory</dt><dd>{str(len(memory))} <small>prior</small></dd></div>
            <div className="bc-tile"><dt>ears</dt><dd style={{"fontSize": "0.95rem"}}>{source if source != "" else "idle"}</dd></div>
        </dl>

        <main className="bc-body">
            <section className="bc-panel">
                <div className="bc-panel-head">
                    <h2>live transcript</h2>
                    <span className="bc-grow"></span>
                    <span className="bc-meta">{startedAt if startedAt != "" else "no session"}</span>
                </div>
                <div className="bc-panel-body bc-scroll bc-feed-h">
                    {if len(utterances) == 0 {
                        <p className="bc-empty">
                            Nothing on the wire yet. Send the bot into a meeting above, or run <code>jac run replay.jac</code> to feed it a scripted one.
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
                <section className="bc-panel">
                    <div className="bc-panel-head">
                        <h2>meeting</h2>
                        <span className="bc-grow"></span>
                        <span className={"bc-status is-live" if botRunning else "bc-status is-off"}>
                            <b></b>{"bot in call" if botRunning else "bot idle"}
                        </span>
                    </div>
                    <div className="bc-panel-body">
                        <div className="bc-row">
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
                                <button className="bc-btn is-danger" onClick={stopTheBot}>stop</button>
                            }}
                        </div>
                        {if botMsg != "" { <p className="bc-note">{botMsg}</p> }}
                        {if botRunning and botLog != "" { <pre className="bc-log">{botLog}</pre> }}
                    </div>
                </section>

                <section className="bc-panel">
                    <div className="bc-panel-head">
                        <h2>knowledge</h2>
                        <span className="bc-grow"></span>
                        <button className="bc-btn" onClick={syncDocs}>rescan</button>
                        <button className="bc-btn" onClick={importOrgDocs}>import repo</button>
                    </div>
                    <div className="bc-panel-body">
                        <div className="bc-inputs">
                            <DropTile
                                kind="rag" accepts="link"
                                title="searchable · link"
                                hint="Fetched, chunked, retrieved when relevant."
                                value={ragUrl} isOver={overTile == "ragUrl"}
                                onValue={lambda (e: ChangeEvent) { ragUrl = e.target.value; }}
                                onSubmit={addRagUrl} onFiles={onRagFiles}
                                onDragOver={lambda (e: any) { dragOver("ragUrl", e); }}
                                onDragLeave={dragLeave}
                                onDrop={lambda (e: any) { dropOn("rag", e); }}
                            />
                            <DropTile
                                kind="rag" accepts="file"
                                title="searchable · files"
                                hint="PDF, .md, .txt. Drop a folder and it takes everything readable."
                                value="" isOver={overTile == "ragFile"}
                                onValue={lambda (e: ChangeEvent) { }}
                                onSubmit={addRagUrl} onFiles={onRagFiles}
                                onDragOver={lambda (e: any) { dragOver("ragFile", e); }}
                                onDragLeave={dragLeave}
                                onDrop={lambda (e: any) { dropOn("rag", e); }}
                            />
                            <DropTile
                                kind="pin" accepts="link"
                                title="always on · link"
                                hint="Fetched once, then sent with every answer."
                                value={pinUrl} isOver={overTile == "pinUrl"}
                                onValue={lambda (e: ChangeEvent) { pinUrl = e.target.value; }}
                                onSubmit={addPinUrl} onFiles={onPinFiles}
                                onDragOver={lambda (e: any) { dragOver("pinUrl", e); }}
                                onDragLeave={dragLeave}
                                onDrop={lambda (e: any) { dropOn("direct", e); }}
                            />
                            <DropTile
                                kind="pin" accepts="file"
                                title="always on · files"
                                hint="Short briefings only — these ride along on every question."
                                value="" isOver={overTile == "pinFile"}
                                onValue={lambda (e: ChangeEvent) { }}
                                onSubmit={addPinText} onFiles={onPinFiles}
                                onDragOver={lambda (e: any) { dragOver("pinFile", e); }}
                                onDragLeave={dragLeave}
                                onDrop={lambda (e: any) { dropOn("direct", e); }}
                            />
                        </div>

                        <div className="bc-row" style={{"marginTop": "0.65rem"}}>
                            <textarea
                                className="bc-input bc-textarea"
                                value={pinText}
                                onChange={lambda (e: ChangeEvent) { pinText = e.target.value; }}
                                placeholder="Or type context to pin: we are the payments team, ACH means…"
                            ></textarea>
                            <button className="bc-btn is-primary" onClick={addPinText}>pin</button>
                        </div>

                        <div className="bc-tags">
                            {if len(docTitles) == 0 and len(pinnedTitles) == 0 {
                                <span className="bc-tag is-empty">no sources yet</span>
                            }}
                            {for t in pinnedTitles {
                                <span className="bc-tag is-pin" key={"p" + str(t)}>{str(t)}</span>
                            }}
                            {for t in docTitles {
                                <span className="bc-tag is-rag" key={"r" + str(t)}>{str(t)}</span>
                            }}
                        </div>
                        {if syncMsg != "" { <p className="bc-note">{syncMsg}</p> }}
                    </div>
                </section>

                <section className="bc-panel">
                    <div className="bc-panel-head">
                        <h2>standing summary</h2>
                        <span className="bc-grow"></span>
                        <button className={"bc-btn is-on" if voiceOn else "bc-btn"} onClick={toggleVoice}>{"voice on" if voiceOn else "voice off"}</button>
                        <button className="bc-btn" onClick={forceSummary}>revise</button>
                        <button className="bc-btn" onClick={endSession}>close</button>
                    </div>
                    <div className="bc-panel-body">
                        {if summary.strip() == "" {
                            <p className="bc-empty">
                                Holding. It revises only on a new finding, a status change, or a correction — never on rewording.
                            </p>
                        }}
                        {if summary.strip() != "" { <pre className="bc-summary">{summary}</pre> }}
                    </div>
                </section>

                <section className="bc-panel">
                    <div className="bc-panel-head">
                        <h2>verdicts</h2>
                        <span className="bc-grow"></span>
                        <span className="bc-meta">{str(len(answers)) + " answered · " + str(len(actions)) + " acted"}</span>
                    </div>
                    <div className="bc-panel-body bc-scroll bc-verdict-h">
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
                    <section className="bc-panel">
                        <div className="bc-panel-head">
                            <h2>carried forward</h2>
                            <span className="bc-grow"></span>
                            <SourceChip source="PRIOR_MEETING"/>
                        </div>
                        <div className="bc-panel-body">
                            {for m in memory {
                                <div className="bc-mem" key={str(m["started_at"])}>
                                    <div className="bc-mem-when">{str(m["started_at"])}</div>
                                    <pre className="bc-mem-text">{str(m["bullets"])}</pre>
                                    {if str(m["decisions"]).strip() != "" {
                                        <pre className="bc-mem-text">{"decisions:" + _NL + str(m["decisions"])}</pre>
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
