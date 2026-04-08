# Copilot Instructions for this repository

## Build, test, and lint commands
This repository does not define a build system, test suite, or lint configuration.

Primary workflow command:

- `.\setup_ai.bat` — runs the full Windows local-AI setup flow.

There is no single-test command because no automated tests are configured.

## High-level architecture
- `setup_ai.bat` is the only source file and contains two layers:
  - A Batch bootstrap section that handles user prompts, prerequisite checks (`winget`), and extraction of embedded PowerShell into a temporary `.ps1`.
  - An embedded PowerShell section between `:__SETUP_AI_PS1__` and `:__SETUP_AI_PS1_END__` that performs setup operations.
- The embedded PowerShell runs this ordered flow:
  - Initialize winget sources.
  - Install LM Studio (`ElementLabs.LMStudio`).
  - Resolve `lms.exe`, then start the local LM Studio server.
  - Ensure required models are installed: `google/gemma-3-4b`, `openai/gpt-oss-20b`, `google/gemma-4-31b`.

## Key conventions
- Keep the marker labels `:__SETUP_AI_PS1__` and `:__SETUP_AI_PS1_END__` exact; Batch extraction depends on them.
- Preserve fail-fast error handling:
  - Batch section uses `if errorlevel ...` and non-zero `exit /b`.
  - PowerShell section uses `$ErrorActionPreference = "Stop"` and explicit `$LASTEXITCODE` checks.
- Route `lms` commands through `Invoke-Lms` to keep output capture and temp-file cleanup consistent.
- Keep model detection normalization (`Normalize-Token` + `Test-ModelInstalled`) when modifying install checks, so `lms ls` formatting differences do not break detection.
- Maintain idempotent behavior: reruns should skip already-installed LM Studio/models when possible.
