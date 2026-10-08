#!/usr/bin/env bash
# Holds one authenticated SSH connection to Frontenac as hpc6081.
# Type password and Microsoft Authenticator code HERE, at the prompts.
# Keep this tab open while Claude runs commands.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
USER_NAME="hpc6081"
HOST="login.cac.queensu.ca"
mkdir -p "$HOME/.ssh"
rm -f "$SOCK"
# A previous master that died mid-auth leaves a socket whose
# session is broken; every later ssh -S then fails with
# "read from master failed: Broken pipe". Clear it first.
ssh -S "$SOCK" -O exit "$USER_NAME@$HOST" 2>/dev/null || true
echo "=============================================="
echo " Frontenac shared connection (hpc6081)"
echo " ssh asks for PASSWORD FIRST, then the OTP/2FA code"
echo " (observed order on 2026-10-05; the banner used to say"
echo "  the reverse, which is an easy way to fail the login)"
echo " Leave this tab open"
echo "=============================================="
exec ssh -M -S "$SOCK" -N \
  -o ServerAliveInterval=60 \
  -o NumberOfPasswordPrompts=3 \
  -o PreferredAuthentications=keyboard-interactive,publickey \
  "$USER_NAME@$HOST"
