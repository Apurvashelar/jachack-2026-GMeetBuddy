"""Backchannel - launch and manage the Meet capture bot from the dashboard.

Paste a Meet URL into the dashboard, click "Send bot", and the server spawns
`ears/bot.py` as a local subprocess. This only makes sense when the brain runs
on a machine with a display (the bot is a headed Chromium window a human can
watch), so it is gated: set BC_ALLOW_BOT=0 to disable, and a hosted deploy
without Playwright installed fails softly with the real error in the report.

The pid is tracked in a file, not module state, so it survives dev-server
reloads.
"""

import os;
import subprocess;


glob PID_FILE: str = ".jac/bot.pid";
glob LOG_FILE: str = ".jac/bot.log";

# The server's own python (the Jac runtime) doesn't have Playwright - the
# user's system python does. Override with BC_BOT_PYTHON if yours differs.
glob BOT_PYTHON: str = os.environ.get("BC_BOT_PYTHON", "/usr/bin/python3");


"""Can this server actually run the Meet bot?

The bot is a headed Chromium window driven by Playwright - it needs a display
and the playwright package. A hosted deploy (JacHammer, k8s) has neither, so
detect that up front and explain it, rather than letting the subprocess die
with a bare "missing dependency" line."""
def bot_capability -> str {
    if os.environ.get("BC_ALLOW_BOT", "1") == "0" {
        return "Bot launching is disabled on this server (BC_ALLOW_BOT=0).";
    }
    if not os.path.exists(BOT_PYTHON) {
        return f"No python interpreter at {BOT_PYTHON}. Set BC_BOT_PYTHON.";
    }
    probe = subprocess.run(
        [BOT_PYTHON, "-c", "import playwright, requests"],
        capture_output=True, timeout=30
    );
    if probe.returncode != 0 {
        return ("Playwright is not installed for this server's python, so the "
                "Meet bot cannot run here. This is expected on a hosted deploy "
                "- the bot needs a real display. Run Backchannel locally to "
                "send a bot into a meeting; the hosted app still ingests "
                "transcripts, answers questions and serves Slack.");
    }
    if not os.environ.get("DISPLAY", "") and os.uname().sysname == "Linux" {
        return ("No display available on this server (headless Linux), so a "
                "headed Chromium cannot start. Run Backchannel locally to "
                "send a bot into a meeting.");
    }
    return "";
}


"""Read the tracked bot pid, 0 when none."""
def bot_pid -> int {
    if not os.path.exists(PID_FILE) {
        return 0;
    }
    try {
        with open(PID_FILE, "r") as fh {
            return int(fh.read().strip());
        }
    } except Exception {
        return 0;
    }
}


"""Is the tracked bot process actually alive right now?"""
def bot_running -> bool {
    pid = bot_pid();
    if pid == 0 {
        return False;
    }
    try {
        os.kill(pid, 0);   # signal 0 = existence check, sends nothing
        return True;
    } except Exception {
        return False;
    }
}


"""Last few lines of the bot's log, for the dashboard status strip."""
def bot_log_tail(lines: int) -> str {
    if not os.path.exists(LOG_FILE) {
        return "";
    }
    try {
        with open(LOG_FILE, "r") as fh {
            content = fh.read();
        }
        return "\n".join(content.strip().split("\n")[-lines:]);
    } except Exception {
        return "";
    }
}


walker:pub StartBot {
    """Spawn ears/bot.py against a Meet URL. One bot at a time."""

    has series: str,
        meet_url: str,
        voice: str = "auto",
        reports: list[dict[any]] = [];

    can run with Root entry {
        blocked = bot_capability();
        if blocked != "" {
            report {"ok": False, "error": blocked};
            disengage;
        }
        if bot_running() {
            report {"ok": False, "error": f"A bot is already running (pid {bot_pid()}). Stop it first."};
            disengage;
        }
        url = self.meet_url.strip();
        if "meet.google.com" not in url {
            report {"ok": False, "error": "That does not look like a Google Meet URL."};
            disengage;
        }
        if not url.startswith("http") {
            url = "https://" + url;
        }

        try {
            logfh = open(LOG_FILE, "w");
            proc = subprocess.Popen(
                [BOT_PYTHON, "-u", "ears/bot.py",   # -u: unbuffered, so the log streams live
                 "--meet-url", url,
                 "--series", self.series,
                 "--brain", "http://localhost:8000",
                 "--voice", self.voice],
                stdout=logfh, stderr=subprocess.STDOUT,
                start_new_session=True
            );
        } except Exception as e {
            report {"ok": False, "error": f"Could not launch bot: {str(e)}. Is Playwright installed? (pip install playwright requests && python -m playwright install chromium)"};
            disengage;
        }

        with open(PID_FILE, "w") as fh {
            fh.write(str(proc.pid));
        }
        report {"ok": True, "pid": proc.pid,
                "note": "Chromium is opening. ADMIT the bot from inside the Meet - it cannot admit itself."};
    }
}


walker:pub StopBot {
    """Kill the tracked bot process."""

    has reports: list[dict[any]] = [];

    can run with Root entry {
        pid = bot_pid();
        if pid == 0 or not bot_running() {
            report {"ok": False, "error": "No bot is running."};
            disengage;
        }
        try {
            # The bot was started in its own session; take the whole group down
            # so Chromium dies with it.
            os.killpg(pid, 15);   # SIGTERM
        } except Exception {
            try {
                os.kill(pid, 15);   # SIGTERM
            } except Exception as e {
                report {"ok": False, "error": f"Could not stop pid {pid}: {str(e)}"};
                disengage;
            }
        }
        if os.path.exists(PID_FILE) {
            os.remove(PID_FILE);
        }
        report {"ok": True, "stopped": pid};
    }
}
