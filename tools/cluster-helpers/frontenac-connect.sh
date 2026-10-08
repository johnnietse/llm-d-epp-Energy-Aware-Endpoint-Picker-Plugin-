#!/usr/bin/env bash
# Holds one authenticated SSH connection to Frontenac open in this tab.
# Type your password and Microsoft Authenticator code HERE, at the ssh prompts.
# Keep this tab open; closing it or Ctrl-C ends the shared connection.
set -u
SOCK="$HOME/.ssh/cm-frontenac"
USER_NAME="sa6079052"
HOST="login.cac.queensu.ca"

mkdir -p "$HOME/.ssh"
rm -f "$SOCK"

echo "=============================================="
echo " Frontenac shared connection"
echo " Type password, then authenticator code, below"
echo " Leave this tab open while Claude runs commands"
echo "=============================================="

exec ssh -M -S "$SOCK" -N \
  -o ServerAliveInterval=60 \
  -o NumberOfPasswordPrompts=3 \
  -o PreferredAuthentications=keyboard-interactive,publickey \
  "$USER_NAME@$HOST"
