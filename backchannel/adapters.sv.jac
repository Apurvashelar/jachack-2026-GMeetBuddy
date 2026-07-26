"""Backchannel - the org-agent adapter seam, plus voice.

`dispatch_action` is the whole point of this file: one function, selected by the
`ORG_AGENT_KIND` env var, that turns an intent expressed out loud in a meeting
into a real effect in a real system. The shipped adapter is GitHub because it is
public and verifiable on stage. An organisation with an internal agent swaps the
adapter here and nothing else in Backchannel changes.

To be explicit about what this is NOT: there is no internal-tool integration in
this repo. The GitHub adapter is the demonstrated one; everything else is a
documented extension point.
"""

import os;
import base64;
import subprocess;
import requests;


glob ORG_AGENT_KIND: str = os.environ.get("ORG_AGENT_KIND", "github");
glob SPEAK_LOCAL: bool = os.environ.get("SPEAK_LOCAL", "") == "1";
glob AUDIO_DEVICE: str = os.environ.get("BC_AUDIO_DEVICE", "coreaudio/BlackHole 2ch");


obj ActionReceipt {
    has status: str = "pending",
        url: str = "",
        detail: str = "";
}


"""File a GitHub issue via the REST API.

This is the GitHub *REST API*, not GitHub Actions CI - Backchannel creates an
issue, it does not run a workflow."""
def github_issue(title: str, series: str, quote: str) -> ActionReceipt {
    pat = os.environ.get("GITHUB_PAT", "").strip();
    owner = os.environ.get("GITHUB_OWNER", "").strip();
    repo = os.environ.get("GITHUB_REPO", "").strip();

    if pat == "" or owner == "" or repo == "" {
        return ActionReceipt(
            status="dry-run",
            url="",
            detail=f"Would file issue '{title}' on {owner or '<owner>'}/{repo or '<repo>'}. Set GITHUB_PAT, GITHUB_OWNER and GITHUB_REPO to make this real."
        );
    }

    body = f"Filed by Backchannel from the meeting '{series}'.\n\nHeard in the meeting:\n\n> {quote}\n";
    try {
        resp = requests.post(
            f"https://api.github.com/repos/{owner}/{repo}/issues",
            headers={
                "Authorization": f"Bearer {pat}",
                "Accept": "application/vnd.github+json"
            },
            json={"title": title, "body": body},
            timeout=30
        );
    } except Exception as e {
        return ActionReceipt(status="error", url="", detail=f"request failed: {str(e)}");
    }

    if resp.status_code == 201 {
        payload = resp.json();
        return ActionReceipt(
            status="created",
            url=payload.get("html_url", ""),
            detail=f"issue #{payload.get('number', '?')} on {owner}/{repo}"
        );
    }
    return ActionReceipt(
        status="error", url="",
        detail=f"GitHub returned {resp.status_code}: {resp.text[:180]}"
    );
}


"""The org-agent adapter. One seam, selected by ORG_AGENT_KIND."""
def dispatch_action(title: str, series: str, quote: str) -> ActionReceipt {
    if ORG_AGENT_KIND == "github" {
        return github_issue(title, series, quote);
    }
    return ActionReceipt(
        status="dry-run", url="",
        detail=f"No adapter registered for ORG_AGENT_KIND={ORG_AGENT_KIND}; would have dispatched '{title}'."
    );
}


"""Render an answer to an mp3 with OpenAI tts-1. Returns the path, or "" when
TTS is unavailable - the dashboard's browser speech synthesis is the baseline
voice and never depends on this."""
def synthesize_speech(text: str, tag: str) -> str {
    key = os.environ.get("OPENAI_API_KEY", "").strip();
    if key == "" or text.strip() == "" {
        return "";
    }
    try {
        body: dict[str, str] = {
            "model": "tts-1", "voice": "alloy", "input": text[:900]
        };
        resp = requests.post(
            "https://api.openai.com/v1/audio/speech",
            headers={"Authorization": f"Bearer {key}"},
            json=body,
            timeout=60
        );
        if resp.status_code != 200 {
            print(f"[backchannel] tts failed {resp.status_code}: {resp.text[:120]}");
            return "";
        }
        os.makedirs("audio", exist_ok=True);
        path = f"audio/answer-{tag}.mp3";
        with open(path, "wb") as fh {
            fh.write(resp.content);
        }
        return path;
    } except Exception as e {
        print(f"[backchannel] tts error: {str(e)}");
        return "";
    }
}


"""Play an mp3 into the virtual mic so the bot's voice lands in the Meet.

Gated behind SPEAK_LOCAL=1 so a hosted deploy no-ops instead of trying to open
an audio device it does not have."""
def speak_local(path: str) -> bool {
    if not SPEAK_LOCAL or path == "" {
        return False;
    }
    try {
        subprocess.Popen(
            ["mpv", "--no-video", f"--audio-device={AUDIO_DEVICE}", path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        );
        return True;
    } except Exception as e {
        print(f"[backchannel] local playback failed: {str(e)}");
        return False;
    }
}
