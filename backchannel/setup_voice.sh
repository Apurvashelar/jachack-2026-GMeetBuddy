#!/usr/bin/env bash
# One-time setup so REMOTE Meet participants can hear Backchannel's answers.
#
# How it works: BlackHole is a virtual audio cable. We make it the system's
# default INPUT device before launching the bot; the bot's Chromium inherits it
# as its microphone. When an answer arrives, the bot plays the audio INTO
# BlackHole -> the Meet transmits it as the bot speaking.
#
# Without this, the bot still works: --voice auto plays answers on your
# laptop speakers (fine when everyone is in the room) and posts them to chat.
set -euo pipefail

echo "Installing BlackHole (virtual audio), SwitchAudioSource and mpv via Homebrew..."
brew install blackhole-2ch switchaudio-osx mpv

echo
echo "Setting default INPUT device to BlackHole (the bot inherits this as its mic)..."
SwitchAudioSource -t input -s "BlackHole 2ch"

echo
echo "Done. Now:"
echo "  1. Launch the bot with:  --voice blackhole   (or pick it in the dashboard)"
echo "  2. AFTER the meeting, restore your real mic:"
echo "       SwitchAudioSource -t input -s \"MacBook Pro Microphone\""
echo
echo "macOS may ask you to approve the BlackHole driver under"
echo "System Settings > Privacy & Security the first time."
