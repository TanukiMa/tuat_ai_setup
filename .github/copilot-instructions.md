# Copilot Instructions for this repository

## Build, test, and lint commands
- `cargo build --release` — builds the Windows executable (`target\release\setup_ai.exe`).
- `cargo run --release` — runs the setup flow locally.

There is no automated test suite or lint configuration in this repository.

## High-level architecture
- `src/main.rs` is the single implementation for the setup flow.
- Distribution target is `setup_ai.exe` built from Rust (`target\release\setup_ai.exe` locally, `dist\setup_ai.exe` in CI release artifacts).
- The Rust executable runs this ordered flow:
  - Initialize winget sources.
  - Install LM Studio (`ElementLabs.LMStudio`).
  - Resolve `lms.exe`, then start the local LM Studio server.
  - Ensure required models are installed: `google/gemma-3-4b`, `openai/gpt-oss-20b`, `google/gemma-4-31b`.

## Key conventions
- Preserve fail-fast behavior with explicit non-zero exit on errors.
- Keep all `lms` operations routed through the shared command runner (`invoke_lms`).
- Keep model detection normalization (`normalize_token` + `test_model_installed`) so `lms ls` formatting differences do not break detection.
- Maintain idempotent behavior: reruns should skip already-installed LM Studio/models when possible.
- Keep CI release binaries portable by static-linking the MSVC runtime (`RUSTFLAGS=-C target-feature=+crt-static` in workflow).
