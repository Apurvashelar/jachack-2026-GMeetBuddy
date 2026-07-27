"""Backchannel - turning whatever someone hands you into grounding material.

Three inputs, one output: plain text in the project's `docs/` folder, ready to
be chunked into the graph.

  * PDFs      - attached in Slack, extracted page by page
  * URLs      - pasted in a message, fetched and stripped to readable text
  * .md/.txt  - taken as-is

Everything is best-effort by design: a password-protected PDF or a 403 from a
paywalled link should cost you one document, never the meeting.
"""

import os;
import re;
import io;
import requests;

import from workspace { workspace_dir }


glob URL_PATTERN: str = r"https?://[^\s<>|]+";
glob FETCH_UA: str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36";


"""Make a string safe to use as a filename."""
def safe_name(name: str) -> str {
    out = "";
    for ch in name {
        if ch.isalnum() or ch in "._-" {
            out += ch;
        } else {
            out += "-";
        }
    }
    return out.strip("-")[:80] or "document";
}


"""Pull every URL out of a chunk of Slack message text."""
def find_urls(text: str) -> list[str] {
    found: list[str] = [];
    for raw in re.findall(URL_PATTERN, text) {
        # Slack wraps links as <https://x|label> and glues trailing punctuation.
        url = str(raw).split("|")[0].rstrip(">.,);:");
        if url not in found {
            found.append(url);
        }
    }
    return found;
}


"""Extract text from PDF bytes. Empty string when it cannot be read."""
def pdf_to_text(blob: bytes) -> str {
    try {
        import from pypdf { PdfReader }
        reader = PdfReader(io.BytesIO(blob));
        pages: list[str] = [];
        # Cap the page count: a 300-page PDF would blow the context window and
        # the API budget, and nobody discusses page 250 in a standup.
        for page in reader.pages[:60] {
            try {
                pages.append(page.extract_text() or "");
            } except Exception {
                continue;
            }
        }
        return "\n\n".join(pages).strip();
    } except Exception as e {
        print(f"[sources] pdf extract failed: {str(e)}");
        return "";
    }
}


"""Strip HTML to something a language model can read."""
def html_to_text(html: str) -> str {
    # Inline flags `(?is)` rather than the flags= kwarg: same semantics, and it
    # keeps the call on the overload the type checker accepts.
    body = html;
    for tag in ["script", "style", "nav", "footer", "svg", "noscript"] {
        body = str(re.sub(rf"(?is)<{tag}[^>]*>.*?</{tag}>", " ", body));
    }
    body = str(re.sub(r"(?i)<br\s*/?>", "\n", body));
    body = str(re.sub(r"(?i)</(p|div|h[1-6]|li|tr)>", "\n", body));
    body = str(re.sub(r"<[^>]+>", " ", body));
    # Unescape the handful of entities that actually show up in prose.
    for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                           ("&gt;", ">"), ("&quot;", '"'), ("&#39;", "'")] {
        body = body.replace(entity, char);
    }
    lines: list[str] = [];
    for line in body.split("\n") {
        stripped = " ".join(line.split());
        if stripped != "" {
            lines.append(stripped);
        }
    }
    return "\n".join(lines);
}


"""Fetch a URL and save it as readable text in the project's docs folder.
Returns the saved filename, or "" on failure."""
def ingest_url(series_name: str, url: str, mode: str = "rag") -> str {
    try {
        resp = requests.get(url, headers={"User-Agent": FETCH_UA}, timeout=25);
        if resp.status_code != 200 {
            print(f"[sources] {url} -> HTTP {resp.status_code}");
            return "";
        }
        ctype = resp.headers.get("content-type", "").lower();
        if "pdf" in ctype or url.lower().endswith(".pdf") {
            text = pdf_to_text(resp.content);
            suffix = "pdf";
        } elif "html" in ctype or ctype == "" {
            text = html_to_text(resp.text);
            suffix = "web";
        } else {
            text = resp.text;
            suffix = "txt";
        }
        if len(text.strip()) < 200 {
            print(f"[sources] {url} produced too little text to be useful");
            return "";
        }
        slug = safe_name(url.split("://")[-1].replace("/", "-"));
        fname = f"{suffix}-{slug}.md";
        folder = "pinned" if mode == "direct" else "docs";
        path = os.path.join(workspace_dir(series_name), folder, fname);
        with open(path, "w") as fh {
            fh.write(f"# Source: {url}\n\n{text}");
        }
        return fname;
    } except Exception as e {
        print(f"[sources] fetch failed for {url}: {str(e)}");
        return "";
    }
}


"""Save a file downloaded from Slack into the project's docs folder.

`blob` is the raw bytes; PDFs are converted to text, markdown and plain text
are stored as-is, anything else is skipped."""
def ingest_blob(series_name: str, filename: str, blob: bytes, mode: str = "rag") -> str {
    lower = filename.lower();
    if lower.endswith(".pdf") {
        text = pdf_to_text(blob);
        if len(text.strip()) < 100 {
            return "";
        }
        fname = f"pdf-{safe_name(filename)}.md";
        body = f"# Source: {filename}\n\n{text}";
    } elif lower.endswith(".md") or lower.endswith(".txt") or lower.endswith(".markdown") {
        try {
            body = blob.decode("utf-8", errors="replace");
        } except Exception {
            return "";
        }
        fname = safe_name(filename);
    } else {
        return "";
    }
    folder = "pinned" if mode == "direct" else "docs";
    path = os.path.join(workspace_dir(series_name), folder, fname);
    with open(path, "w") as fh {
        fh.write(body);
    }
    return fname;
}


"""Save literal text the user typed as always-in-context briefing material.

The "direct input" path: no fetching, no chunking - what you type is what the
model sees on every answer."""
def ingest_text(series_name: str, title: str, text: str) -> str {
    if len(text.strip()) < 5 {
        return "";
    }
    fname = f"{safe_name(title)}.md";
    path = os.path.join(workspace_dir(series_name), "pinned", fname);
    with open(path, "w") as fh {
        fh.write(f"# {title}\n\n{text.strip()}");
    }
    return fname;
}
