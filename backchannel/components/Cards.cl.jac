"""Backchannel dashboard cards.

The source badge is the visual payoff of the typed return in `ai.sv.jac`:
`GroundedAnswer.source` is an enum, so the UI can colour-code provenance without
parsing prose. UNKNOWN is styled as a first-class, non-alarming answer - an
honest "not in the context" is the behaviour we want to show off, not hide.
"""

glob SOURCE_COLORS: dict[str, str] = {
    "DOC": "#4c8dff",
    "TRANSCRIPT": "#33c46f",
    "PRIOR_MEETING": "#a274ff",
    "UNKNOWN": "#f0a832"
};

glob SOURCE_LABELS: dict[str, str] = {
    "DOC": "GROUNDED IN DOC",
    "TRANSCRIPT": "FROM THIS MEETING",
    "PRIOR_MEETING": "FROM A PRIOR MEETING",
    "UNKNOWN": "NOT IN CONTEXT"
};


def:pub SourceBadge(source: str) -> JsxElement {
    color = SOURCE_COLORS.get(source, "#8b93a7");
    label = SOURCE_LABELS.get(source, source);
    return <span
        style={{
            "display": "inline-block", "padding": "0.2rem 0.55rem",
            "borderRadius": "999px", "fontSize": "0.65rem",
            "fontWeight": "700", "letterSpacing": "0.08em",
            "color": color, "border": "1px solid " + color,
            "backgroundColor": color + "18"
        }}
    >{label}</span>;
}


def:pub AnswerCard(question: str, answer: str, source: str, quote: str) -> JsxElement {
    color = SOURCE_COLORS.get(source, "#8b93a7");
    return <div
        style={{
            "borderLeft": "3px solid " + color,
            "backgroundColor": "#161a24", "borderRadius": "10px",
            "padding": "0.85rem 1rem", "marginBottom": "0.75rem"
        }}
    >
        <div style={{"display": "flex", "justifyContent": "space-between", "alignItems": "center", "gap": "0.5rem"}}>
            <span style={{"color": "#8b93a7", "fontSize": "0.72rem", "letterSpacing": "0.06em"}}>ASKED</span>
            <SourceBadge source={source}/>
        </div>
        <p style={{"margin": "0.3rem 0 0.7rem", "color": "#c9d1e0", "fontSize": "0.9rem"}}>{question}</p>
        <p style={{"margin": "0", "color": "#f2f5fa", "fontSize": "1rem", "lineHeight": "1.5"}}>{answer}</p>
        {if quote != "" {
            <blockquote
                style={{
                    "margin": "0.75rem 0 0", "padding": "0.5rem 0.75rem",
                    "borderLeft": "2px solid #2b3243", "color": "#7f8798",
                    "fontSize": "0.78rem", "fontStyle": "italic", "lineHeight": "1.45"
                }}
            >{quote}</blockquote>
        }}
    </div>;
}


def:pub ActionCard(payload: str, status: str, url: str, detail: str) -> JsxElement {
    ok = status == "created";
    color = "#33c46f" if ok else ("#f0a832" if status == "dry-run" else "#ff5d5d");
    return <div
        style={{
            "borderLeft": "3px solid " + color,
            "backgroundColor": "#161a24", "borderRadius": "10px",
            "padding": "0.85rem 1rem", "marginBottom": "0.75rem"
        }}
    >
        <div style={{"display": "flex", "justifyContent": "space-between", "alignItems": "center", "gap": "0.5rem"}}>
            <span style={{"color": "#8b93a7", "fontSize": "0.72rem", "letterSpacing": "0.06em"}}>ORG-AGENT ACTION</span>
            <span
                style={{
                    "color": color, "fontSize": "0.65rem", "fontWeight": "700",
                    "letterSpacing": "0.08em", "border": "1px solid " + color,
                    "borderRadius": "999px", "padding": "0.2rem 0.55rem",
                    "backgroundColor": color + "18"
                }}
            >{status.upper()}</span>
        </div>
        <p style={{"margin": "0.4rem 0 0.5rem", "color": "#f2f5fa", "fontSize": "0.95rem"}}>{payload}</p>
        <p style={{"margin": "0", "color": "#7f8798", "fontSize": "0.75rem"}}>{detail}</p>
        {if url != "" {
            <a
                href={url} target="_blank" rel="noreferrer"
                style={{"display": "inline-block", "marginTop": "0.55rem", "color": "#4c8dff", "fontSize": "0.8rem"}}
            >{url}</a>
        }}
    </div>;
}


def:pub FeedLine(speaker: str, text: str, isWake: bool) -> JsxElement {
    return <div
        style={{
            "padding": "0.35rem 0.6rem", "marginBottom": "0.2rem",
            "borderRadius": "6px", "fontSize": "0.85rem", "lineHeight": "1.5",
            "backgroundColor": "#1d2536" if isWake else "transparent",
            "borderLeft": ("2px solid #4c8dff" if isWake else "2px solid transparent")
        }}
    >
        <span style={{"color": "#4c8dff" if isWake else "#6f7891", "fontWeight": "600", "marginRight": "0.5rem"}}>{speaker}</span>
        <span style={{"color": "#dfe5ef" if isWake else "#a6aebf"}}>{text}</span>
    </div>;
}
