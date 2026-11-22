# Autocoder Changelog

Changes waiting for the next release go under `## [Unreleased]`. Issue branches
add entries here and never bump a version; the release bumps every manifest at
once (Version Management in `docs/maintaining.md`).

## [Unreleased]

### Added

- `/review-blocked-gui` (#308): review blocked issues in a local web page. It
  starts `review-blocked-server.py` (#311) on `127.0.0.1`, prints a URL with a
  per-run token, and suggests `/review-blocked --prepare` when issues have no
  current analysis. The page (`review-blocked-ui.html`, #313) shows each issue's
  block reason, body and analysed options, and records approve, reject, ask and
  skip decisions, one at a time or in a batch. `/review-blocked --prepare` (#312)
  fills the analysis cache (`blocked-analysis-cache.py`, #310) without asking
  anything. `--stop` ends the server.
- The script packager also ships `review-blocked-ui.html` next to the server on
  every platform whose package carries `review-blocked-server.py`.
