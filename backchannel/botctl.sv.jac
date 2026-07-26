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
        if os.environ.get("BC_ALLOW_BOT", "1") == "0" {
            report {"ok": False, "error": "Bot launch disabled on this server (BC_ALLOW_BOT=0)."};
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
                ["python3", "ears/bot.py",
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
