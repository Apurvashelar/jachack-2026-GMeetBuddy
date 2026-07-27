"""Backchannel console - verdict and feed cards.

The provenance stripe is the whole point of these components: `source` is an
enum on the server, so the interface can encode where evidence came from as
colour and shape rather than making the reader parse prose.

UNKNOWN is deliberately styled as the calm one - dashed outline, neutral grey.
An honest "not in the context" is the behaviour worth showing off, not an error
state to paint red.
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


"""Seconds since session start, as mm:ss - the feed's timecode gutter."""
def timecode(ms: int) -> str {
    total = int(ms / 1000);
    mins = int(total / 60);
    secs = total % 60;
    return str(mins).zfill(2) + ":" + str(secs).zfill(2);
}


def:pub SourceChip(source: str) -> JsxElement {
    label = SOURCE_LABELS.get(source, source.lower());
    cls = "bc-chip is-unknown" if source == "UNKNOWN" else "bc-chip";
    return <span className={cls}>{label}</span>;
}


def:pub AnswerCard(question: str, answer: str, source: str, quote: str) -> JsxElement {
    return <article className="bc-verdict" style={{"--src": SOURCE_VARS.get(source, "var(--src-unknown)")}}>
        <div className="bc-verdict-head">
            <SourceChip source={source}/>
        </div>
        <p className="bc-question">{question}</p>
        <p className="bc-answer">{answer}</p>
        {if quote != "" {
            <blockquote className="bc-quote">{quote}</blockquote>
        }}
    </article>;
}


def:pub ActionCard(payload: str, status: str, url: str, detail: str) -> JsxElement {
    tone = "var(--src-transcript)" if status == "created" else ("var(--signal)" if status == "dry-run" else "var(--alert)");
    return <article className="bc-verdict" style={{"--src": tone}}>
        <div className="bc-verdict-head">
            <span className="bc-chip">{status}</span>
            <span className="bc-question" style={{"margin": "0"}}>org-agent action</span>
        </div>
        <p className="bc-answer">{payload}</p>
        <p className="bc-question" style={{"margin": "0.4rem 0 0"}}>{detail}</p>
        {if url != "" {
            <a className="bc-link" href={url} target="_blank" rel="noreferrer">{url}</a>
        }}
    </article>;
}


def:pub FeedLine(speaker: str, text: str, isCue: bool, tsMs: int) -> JsxElement {
    return <div className={"bc-line is-cue" if isCue else "bc-line"}>
        <span className="bc-time">{timecode(tsMs)}</span>
        <span className="bc-said">
            {if isCue {
                <span className="bc-cue-tag">CUE</span>
            }}
            <span className="bc-speaker">{speaker}</span>
            {text}
        </span>
    </div>;
}
