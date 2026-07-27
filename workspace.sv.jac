"""Backchannel - per-meeting workspaces on plain disk.

Every meeting series gets a folder:

    meetings/<slug>/
      docs/         drop .md / .txt files here; SyncWorkspace ingests them all
      context.md    appended after every session (distilled memory)

Two reasons this exists alongside the graph:

1. Humans need a drop-zone. "Put the paper in the folder" beats crafting a
   curl request.
2. `context.md` is memory that survives EVERYTHING - even `rm -rf .jac/data`.
   AnswerQuestion reads it as PRIOR_MEETING evidence in addition to the graph's
   SessionSummary nodes, so the bot walks into next week's meeting already
   knowing what was decided.

Google Drive, without an API: point BC_MEETINGS_DIR at a folder inside
"Google Drive for desktop" (e.g. ~/Google Drive/My Drive/backchannel) and every
workspace - context files and doc drop-zones - syncs to Drive and can be shared
with colleagues. No OAuth, no service accounts, no code.
"""

import os;


glob MEETINGS_DIR: str = os.environ.get("BC_MEETINGS_DIR", "meetings");

glob CHUNK_CHARS: int = 1000;


"""Split a document into ~CHUNK_CHARS blocks on paragraph boundaries."""
def chunk_text(text: str) -> list[str] {
    chunks: list[str] = [];
    current = "";
    for para in text.split("\n\n") {
        if len(current) + len(para) > CHUNK_CHARS and len(current) > 0 {
            chunks.append(current.strip());
            current = "";
        }
        current = current + para + "\n\n";
    }
    if len(current.strip()) > 0 {
        chunks.append(current.strip());
    }
    return chunks;
}


"""Filesystem-safe slug for a series name."""
def series_slug(name: str) -> str {
    out = "";
    for ch in name.lower() {
        if ch.isalnum() {
            out += ch;
        } elif len(out) > 0 and not out.endswith("-") {
            out += "-";
        }
    }
    return out.strip("-") or "meeting";
}


"""The series' workspace folder; created (with docs/) on first touch."""
def workspace_dir(series_name: str) -> str {
    path = os.path.join(MEETINGS_DIR, series_slug(series_name));
    os.makedirs(os.path.join(path, "docs"), exist_ok=True);
    os.makedirs(os.path.join(path, "pinned"), exist_ok=True);
    return path;
}


"""Read the persistent context file. Empty string when there is none yet."""
def read_context_file(series_name: str) -> str {
    path = os.path.join(workspace_dir(series_name), "context.md");
    if not os.path.exists(path) {
        return "";
    }
    with open(path, "r") as fh {
        return fh.read();
    }
}


"""Append one session's distilled memory to the context file."""
def append_context_file(series_name: str, started_at: str, bullets: str, decisions: str) {
    path = os.path.join(workspace_dir(series_name), "context.md");
    is_new = not os.path.exists(path);
    with open(path, "a") as fh {
        if is_new {
            fh.write(f"# Backchannel context - {series_name}\n\n");
            fh.write("Written automatically after each session. Read back as PRIOR_MEETING\n");
            fh.write("evidence in future sessions. Safe to edit by hand.\n");
        }
        fh.write(f"\n## Session of {started_at}\n\n{bullets.strip()}\n");
        if decisions.strip() != "" {
            fh.write(f"\n**Decisions:**\n{decisions.strip()}\n");
        }
    }
}


"""Every readable document in a series' workspace as (name, text, mode).

Scans both drop-zones: `docs/` is retrieved by relevance, `pinned/` is sent
with every single answer."""
def list_workspace_docs(series_name: str) -> list[tuple] {
    base = workspace_dir(series_name);
    found: list[tuple] = [];
    for (folder, mode) in [("docs", "rag"), ("pinned", "direct")] {
        folder_path = os.path.join(base, folder);
        if not os.path.isdir(folder_path) {
            continue;
        }
        for fname in sorted(os.listdir(folder_path)) {
            lower = fname.lower();
            if not (lower.endswith(".md") or lower.endswith(".txt") or lower.endswith(".markdown")) {
                continue;
            }
            try {
                with open(os.path.join(folder_path, fname), "r") as fh {
                    found.append((fname, fh.read(), mode));
                }
            } except Exception as e {
                print(f"[backchannel] could not read {fname}: {str(e)}");
            }
        }
    }
    return found;
}
