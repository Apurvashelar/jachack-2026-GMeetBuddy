"""Every Google Meet selector Backchannel depends on, in one file.

Meet's DOM is not a public API and it shifts. When the bot stops seeing
captions, this is the only file that should need editing: open devtools on a
live Meet, inspect the caption text, walk up to a stable container, and add the
selector you actually see to the front of the relevant list.

Each entry is a list of CANDIDATES tried in order, so adding a new selector
never breaks the old one.
"""

# Pre-join screen -------------------------------------------------------------

# The "your name" input only exists when you are NOT signed into a Google
# account. Its presence is how the bot knows it is joining as a guest.
NAME_INPUT = [
    "input[aria-label*='name' i]",
    "input[placeholder*='name' i]",
]

# Consent / info popups that sit on top of the pre-join screen.
DISMISS_BUTTONS = [
    "button:has-text('Got it')",
    "button:has-text('Dismiss')",
    "button:has-text('Continue without microphone')",
    "button:has-text('Close')",
]

# Pre-join mic/camera toggles. Backchannel joins muted and dark - it is there to
# listen, and an unexpected hot mic in someone's meeting is not acceptable.
MIC_TOGGLE = [
    "[aria-label*='Turn off microphone' i]",
    "div[role='button'][aria-label*='microphone' i]",
]
CAM_TOGGLE = [
    "[aria-label*='Turn off camera' i]",
    "div[role='button'][aria-label*='camera' i]",
]

JOIN_BUTTONS = [
    "button:has-text('Ask to join')",
    "button:has-text('Join now')",
    "span:has-text('Ask to join')",
    "span:has-text('Join now')",
]

# In-call ---------------------------------------------------------------------

# Presence of ANY of these is the bot's "I am actually in the meeting" signal.
# The chat/people buttons only exist in-call, so they back up the Leave button
# in case its aria-label shifts.
IN_CALL_MARKER = [
    "[aria-label*='Leave call' i]",
    "button[aria-label*='Leave call' i]",
    "[aria-label*='Chat with everyone' i]",
    "[aria-label*='Show everyone' i]",
    "[aria-label*='People' i]",
]

CAPTIONS_BUTTON = [
    "button[aria-label*='Turn on captions' i]",
    "div[role='button'][aria-label*='Turn on captions' i]",
    "[aria-label*='Turn on captions' i]",
    "[data-tooltip*='captions' i]",
    "button[aria-label*='caption' i]",
    "div[role='button'][aria-label*='caption' i]",
    "[aria-label*='subtitles' i]",
]

# The caption region. Order matters: the most specific container first, so the
# MutationObserver watches the smallest subtree that still contains every line.
CAPTION_REGIONS = [
    "div[aria-label='Captions']",
    "div[jsname='dsyhDe']",
    "div[role='region'][aria-label*='caption' i]",
    ".a4cQT",
]

# Within one caption block: who is speaking, and what they said.
SPEAKER_IN_BLOCK = [".zs7s8d", ".KcIKyf", "[class*='name']"]
TEXT_IN_BLOCK = [".bh44bd", ".iTTPOb", "[class*='text']"]

# Chat (used to post answers into the meeting as the no-audio baseline) --------

CHAT_OPEN_BUTTON = [
    "[aria-label*='Chat with everyone' i]",
    "button[aria-label*='chat' i]",
]
CHAT_INPUT = [
    "textarea[aria-label*='Send a message' i]",
    "textarea[placeholder*='Send a message' i]",
]
CHAT_SEND = [
    "button[aria-label*='Send a message' i]",
    "button[aria-label*='Send' i]",
]
