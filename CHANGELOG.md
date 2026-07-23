# Changelog

## Unreleased
- Dropped the 0.2.93 citation-sentinel prompt workaround from the web GUARD (bug fixed upstream; the sentinel string is absent from grok 0.2.101+ source). The collection-quality rules (no UA spoofing, no shell-based fetch, verbatim quote + source URL per claim) are retained verbatim.
