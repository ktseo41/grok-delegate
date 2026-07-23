# Changelog

## Unreleased
- Dropped the 0.2.93 citation-sentinel prompt workaround from the web GUARD (bug fixed upstream; the sentinel string is absent from grok 0.2.101+ source). The collection-quality rules (no UA spoofing, no shell-based fetch, verbatim quote + source URL per claim) are retained verbatim.
- Removed the `research-rw` mode (vestigial old-grok fallback; with the user's explicit OK, `fix -w <name>` covers web work that needs write+shell). `research-rw` now exits 2 as an unknown mode.
- Removed the dead pre-0.2.98 version-gate machinery (`VERSION_BUG_POSSIBLE` and the two-way build-error diagnosis). A research session-build error now retries once unconditionally, then fails closed with one unified message. Version detection remains for the `--verify` >= 0.2.111 hard gate plus a new non-blocking startup warning on grok < 0.2.98. Declared floor: grok >= 0.2.98 for `research`, >= 0.2.111 for `--verify`.
