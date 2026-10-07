#!/usr/bin/env python3
"""Mirrors what 'ssh -t' does to the local terminal.

ssh only puts the terminal into raw mode when stdin is a tty, and raw mode
means tcsetattr(). tcsetattr() from a background process group always raises
SIGTTOU, whatever the TOSTOP setting is. This is the exact step that stops
acloud during 'Launching AVD(s) and waiting for boot up'.
"""
import sys
import termios

fd = sys.stdin.fileno()
if not sys.stdin.isatty():
    print("stdin is not a tty, skipping raw mode (this is what ssh -t does)")
    print("SURVIVED")
    sys.exit(0)

print("stdin is a tty, entering raw mode")
sys.stdout.flush()
attrs = termios.tcgetattr(fd)
termios.tcsetattr(fd, termios.TCSADRAIN, attrs)
print("SURVIVED")
