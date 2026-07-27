"""Backchannel - verdict and transcript cards.

The provenance stripe is the point: `source` is an enum on the server, so the
interface encodes where evidence came from as colour and shape rather than
making anyone parse prose. UNKNOWN is deliberately the calm one - dashed and
neutral - because an honest "not in the context" is the behaviour worth showing
off, not an error to paint red.
"""

glob SOURCE_LABELS: dict[str, str] = {
    "DOC": "grounded in doc",
    "TRANSCRIPT": "from this meeting",
    "PRIOR_MEETING": "from a prior meeting",
    "UNKNOWN": "not in context"
};

glob SOURCE_VARS: dict[str, str] = {
    "DOC": "var(--src-doc)",
    "TRANSCRIPT": "var(--src-transcript)",
    "PRIOR_MEETING": "var(--src-prior)",
    "UNKNOWN": "var(--src-unknown)"
};


"""Milliseconds since session start as mm:ss - the feed's timecode gutter."""
def timecode(ms: int) -> str {
    total = int(ms / 1000);
    return str(int(total / 60)).zfill(2) + ":" + str(total % 60).zfill(2);
}


def:pub SourceChip(source: str) -> JsxElement {
    return <span
        className={"bc-chip is-unknown" if source == "UNKNOWN" else "bc-chip"}
        style={{"--src": SOURCE_VARS.get(source, "var(--src-unknown)")}}
    >{SOURCE_LABELS.get(source, source.lower())}</span>;
}


def:pub AnswerCard(question: str, answer: str, source: str, quote: str) -> JsxElement {
    return <article className="bc-verdict" style={{"--src": SOURCE_VARS.get(source, "var(--src-unknown)")}}>
        <div className="bc-verdict-head">
            <SourceChip source={source}/>
        </div>
        <p className="bc-q">{question}</p>
        <p className="bc-a">{answer}</p>
        {if quote != "" {
            <blockquote className="bc-quote">{quote}</blockquote>
        }}
    </article>;
}


def:pub ActionCard(payload: str, status: str, url: str, detail: str) -> JsxElement {
    tone = "var(--mint)" if status == "created" else ("var(--amber)" if status == "dry-run" else "var(--coral)");
    return <article className="bc-verdict" style={{"--src": tone}}>
        <div className="bc-verdict-head">
            <span className="bc-chip" style={{"--src": tone}}>{status}</span>
            <span className="bc-meta">org-agent action</span>
        </div>
        <p className="bc-a">{payload}</p>
        <p className="bc-q" style={{"margin": "0.45rem 0 0"}}>{detail}</p>
        {if url != "" {
            <a className="bc-link" href={url} target="_blank" rel="noreferrer">{url}</a>
        }}
    </article>;
}


def:pub FeedLine(speaker: str, text: str, isCue: bool, tsMs: int) -> JsxElement {
    return <div className={"bc-line is-cue" if isCue else "bc-line"}>
        <span className="bc-tc">{timecode(tsMs)}</span>
        <span className="bc-said">
            {if isCue {
                <span className="bc-cue">CUE</span>
            }}
            <span className="bc-who">{speaker}</span>
            {text}
        </span>
    </div>;
}


"""One of the four intake tiles.

`kind` is the destination (rag | pin) and `accepts` is the payload shape
(link | file). Keeping them as one component makes the 2x2 grid literally a
grid of the same thing, which is what the two dimensions deserve."""
def:pub DropTile(
    kind: str, accepts: str, title: str, hint: str,
    value: str, isOver: bool,
    onValue: any, onSubmit: any, onFiles: any,
    onDragOver: any, onDragLeave: any, onDrop: any
) -> JsxElement {
    cls = "bc-drop is-rag" if kind == "rag" else "bc-drop is-pin";
    if isOver {
        cls = cls + " is-over";
    }
    return <div
        className={cls}
        onDragOver={onDragOver}
        onDragLeave={onDragLeave}
        onDrop={onDrop}
    >
        <div className="bc-drop-head">
            <span className="bc-drop-kind">{title}</span>
        </div>
        <p className="bc-drop-hint">{hint}</p>
        {if accepts == "link" {
            <div className="bc-row">
                <input
                    className="bc-input"
                    type="text"
                    value={value}
                    onChange={onValue}
                    placeholder="https://…"
                />
                <button className="bc-btn is-primary" onClick={onSubmit}>add</button>
            </div>
        }}
        {if accepts == "file" {
            <label className="bc-file">
                drop files here, or browse
                <input type="file" multiple onChange={onFiles}/>
            </label>
        }}
        {if accepts == "folder" {
            <label className="bc-file">
                drop a folder here, or browse
                <input type="file" multiple webkitdirectory="" directory="" onChange={onFiles}/>
            </label>
        }}
        {if accepts == "text" {
            <div className="bc-row">
                <textarea
                    className="bc-input bc-textarea"
                    value={value}
                    onChange={onValue}
                    placeholder="We are the payments team. ACH means…"
                ></textarea>
                <button className="bc-btn is-primary" onClick={onSubmit}>pin</button>
            </div>
        }}
    </div>;
}
