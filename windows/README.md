# Fujify for Windows

Not built yet.

The design is drafted and the shared pipeline contract is written, so the
port is a matter of implementation rather than discovery:

- [`docs/PIPELINE-CONTRACT.md`](../docs/PIPELINE-CONTRACT.md) — the normative
  spec every implementation follows. §3.4, §4.1 and §5.3 already record the
  Windows-specific differences.
- [`docs/plans/2026-09-21-windows-port-prerequisites.md`](../docs/plans/2026-09-21-windows-port-prerequisites.md)
  — what has to be verified on a real Windows install first.
- [`docs/plans/2026-09-21-design-first.md`](../docs/plans/2026-09-21-design-first.md)
  — the agreed Fluent design for every screen.

In the meantime, [Fujify for the web](../web/) runs in Edge and Chrome on
Windows and does everything except convert RAW files to DNG.
