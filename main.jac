"""
Every endpoint the client or the ears can reach MUST be named in the import
list below - a walker missing from here answers 405 no matter how correct it is.
"""

import from graph {
    MeetingSeries, Session, Utterance, Answer, Action, Doc, DocChunk, SessionSummary
}

import from ingest { IngestChunk, Tick, LoadDoc, SyncWorkspace, ImportOrgDocs }

import from answer { AnswerQuestion, ExecuteAction, EndSession, Summarize }

import from botctl { StartBot, StopBot }

# Client-side UI
cl {
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
