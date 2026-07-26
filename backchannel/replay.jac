"""Backchannel replay - the deterministic pair of ears.

Feeds `data/script.txt` through the exact same `POST /walker/IngestChunk` inlet
the live Playwright bot uses, with realistic delays. Nothing about the brain
knows the difference, which is the point: the ingest contract is the seam.

    jac run replay.jac                       # default series, default speed
    BC_SERIES="Research Weekly Sync" BC_DELAY=1.2 jac run replay.jac
"""

import os;
import sys;
import time;
import requests;


glob BRAIN: str = os.environ.get("BC_BRAIN", "http://localhost:8000");
glob SERIES: str = os.environ.get("BC_SERIES", "Research Weekly Sync");
glob DELAY: float = float(os.environ.get("BC_DELAY", "1.4"));
glob SCRIPT: str = os.environ.get("BC_SCRIPT", "data/script.txt");
glob DOC: str = os.environ.get("BC_DOC", "data/paper.md");


"""Read a UTF-8 file off disk."""
def read_file(path: str) -> str {
    with open(path, "r") as fh {
        return fh.read();
    }
}


"""Parse `Speaker|text` lines, skipping blanks and #-comments."""
def parse_script(raw: str) -> list[tuple] {
    lines: list[tuple] = [];
    for line in raw.split("\n") {
        stripped = line.strip();
        if stripped == "" or stripped.startswith("#") {
            continue;
        }
        if "|" not in stripped {
            continue;
        }
        parts = stripped.split("|", 1);
        lines.append((parts[0].strip(), parts[1].strip()));
    }
    return lines;
}


"""POST one walker spawn to the brain and return the decoded envelope."""
def post_walker(name: str, body: dict[any]) -> any {
    resp = requests.post(f"{BRAIN}/walker/{name}", json=body, timeout=120);
    if resp.status_code != 200 {
        print(f"  ! {name} -> HTTP {resp.status_code}: {resp.text[:200]}");
        return {};
    }
    return resp.json();
}


"""Pull the report list out of a walker response envelope, typed."""
def reports_of(env: any) -> list[dict[any]] {
    out: list[dict[any]] = [];
    if not env or "data" not in env {
        return out;
    }
    data = env["data"];
    if not data or "reports" not in data {
        return out;
    }
    for r in data["reports"] {
        out.append(r);
    }
    return out;
}


"""Push the grounding document onto the series before any transcript flows."""
def load_doc {
    if not os.path.exists(DOC) {
        print(f"  ! grounding doc {DOC} not found, skipping LoadDoc");
        return;
    }
    text = read_file(DOC);
    env = post_walker("LoadDoc", {
        "series": SERIES,
        "title": "MTP: A Meaning-Typed Language Abstraction for AI-Integrated Programming",
        "text": text
    });
    reports = reports_of(env);
    if reports {
        print(f"  doc loaded: {reports[0].get('chunks')} chunks");
    }
}


"""Stream the scripted transcript through the ingest inlet."""
def stream_script {
    rows = parse_script(read_file(SCRIPT));
    print(f"  {len(rows)} scripted lines -> {BRAIN} (series: {SERIES})");
    started = time.time();
    for (i, row) in enumerate(rows) {
        speaker = row[0];
        text = row[1];
        elapsed = int((time.time() - started) * 1000);
        env = post_walker("IngestChunk", {
            "series": SERIES, "speaker": speaker, "text": text,
            "caption_id": f"replay-{i}", "version": 1,
            "ts_ms": elapsed, "source": "replay"
        });
        # A wake hit spawns AnswerQuestion/ExecuteAction inline, and a nested
        # walker's reports land in the SAME response stream ahead of the
        # inlet's own - so scan for the report that carries the wake field
        # rather than assuming slot 0.
        wake = "";
        detail = "";
        for row in reports_of(env) {
            if "wake" in row {
                wake = str(row.get("wake", ""));
            }
            if row.get("kind") == "answer" {
                detail = f"[{row.get('source')}] {str(row.get('answer'))[:150]}";
            } elif row.get("kind") == "action" {
                detail = f"[{row.get('status')}] {row.get('detail')}";
            }
        }
        marker = "  >>" if wake else "    ";
        print(f"{marker} {speaker}: {text}");
        if wake {
            print(f"       ^ wake fired, ask = {wake!r}");
        }
        if detail != "" {
            print(f"       -> {detail}");
        }
        time.sleep(DELAY);
    }
    print("  replay complete.");
}


with entry:__main__ {
    print(f"Backchannel replay -> {BRAIN}");
    if "--no-doc" not in sys.argv {
        load_doc();
    }
    stream_script();
}
