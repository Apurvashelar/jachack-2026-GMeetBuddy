"""Backchannel - a self-hosted Google Meet copilot whose brain is a Jac graph.

Every endpoint the client or the ears can reach MUST be named in the import
list below - a walker missing from here answers 405 no matter how correct it is.
"""

import from graph {
    MeetingSeries, Session, Utterance, Answer, Action, Doc, DocChunk, SessionSummary
}

import from ingest { IngestChunk, Tick, LoadDoc, SyncWorkspace, ImportOrgDocs, AddSource, StartMeeting, Projects }

import from answer { AnswerQuestion, ExecuteAction, EndSession, Summarize }

import from botctl { StartBot, StopBot, NextBotRequest, CancelBotRequests }

import from slashcmd { SlackCommand }

# Client-side UI
cl {
    import ".styles/global.css";

    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
