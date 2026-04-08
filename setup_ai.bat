@echo off
setlocal EnableExtensions
chcp 65001 >nul
:: --------------------------------------------------------
:: Local AI setup automation script
:: --------------------------------------------------------

set "QUESTIONNAIRE_URL=https://forms.gle/aAFcQ4W4UBrfECZy7"

echo(===================================================
echo( [IMPORTANT] Do not use 4G/5G mobile network.
echo( Please run this script on the TUAT campus network.
echo(===================================================
echo(

choice /C YN /N /M "Stop setup? [Y/n] "
if errorlevel 2 goto continue_setup
if errorlevel 1 (
    echo(
    echo(Setup was cancelled.
    goto :EOF
)

:continue_setup
echo(

:: Check if winget is available.
where winget >nul 2>nul
if errorlevel 1 (
    echo([ERROR] winget was not found.
    echo(Please update "App Installer" in Microsoft Store, then run again.
    echo(
    pause
    exit /b 1
)

echo(===================================================
echo( Starting setup for local AI environment.
echo( This may take 10 to 30 minutes.
echo(===================================================
echo(

:: Generate and run embedded PowerShell setup script.
set "SETUP_PS1=%TEMP%\setup_ai_%RANDOM%_%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$source = '%~f0'; $dest = $env:SETUP_PS1; $startMarker = ':__SETUP_AI_PS1__'; $endMarker = ':__SETUP_AI_PS1_END__'; $all = Get-Content -LiteralPath $source -Encoding UTF8; $start = [Array]::IndexOf($all, $startMarker); $end = [Array]::IndexOf($all, $endMarker); if ($start -lt 0 -or $end -lt 0 -or $end -le ($start + 1)) { throw 'Embedded PowerShell setup script was not found or is empty.' }; Set-Content -LiteralPath $dest -Value $all[($start + 1)..($end - 1)] -Encoding UTF8"
if errorlevel 1 (
    echo(
    echo([ERROR] Failed to prepare internal PowerShell script.
    echo(
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%"
set "SETUP_EXIT=%ERRORLEVEL%"
del /f /q "%SETUP_PS1%" >nul 2>nul

if not "%SETUP_EXIT%"=="0" (
    echo(
    echo([ERROR] Setup failed. Please review the messages above.
    echo(
    pause
    exit /b 1
)

echo(
echo(===================================================
echo( Please answer the survey after setup.
echo( URL: %QUESTIONNAIRE_URL%
echo(===================================================
echo(
start "" "%QUESTIONNAIRE_URL%" >nul 2>nul
pause
exit /b 0

:__SETUP_AI_PS1__
$ErrorActionPreference = "Stop"

$packageId = "ElementLabs.LMStudio"
$models = @(
    "google/gemma-3-4b"
    "openai/gpt-oss-20b"
    "google/gemma-4-31b"
)

function Initialize-WingetSources {
    winget --version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to start."
    }

    winget source list --disable-interactivity *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "winget source list failed."
    }

    winget source update --disable-interactivity *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "winget source update failed once. Continuing and retrying via install/list commands..." -ForegroundColor Yellow
    }
}

function Ensure-LmStudioInstalled([string]$PackageId) {
    $installOutput = winget install --id $PackageId --exact --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        winget source update --disable-interactivity *> $null
        $installOutput = winget install --id $PackageId --exact --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-String
    }

    if ($LASTEXITCODE -ne 0) {
        $installedCheck = winget list --id $PackageId --exact --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        if ($installedCheck -match [regex]::Escape($PackageId)) {
            Write-Host "LM Studio is already installed. Skipping install." -ForegroundColor Yellow
            return
        }
        Write-Host $installOutput
        throw "LM Studio installation failed."
    }
}

function Ensure-LmsCommandReady {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\LM Studio\resources\app\.webpack\lms.exe")
        (Join-Path $env:ProgramFiles "LM Studio\resources\app\.webpack\lms.exe")
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "LM Studio\resources\app\.webpack\lms.exe")
    }

    $existing = Get-Command lms -ErrorAction SilentlyContinue
    if ($existing) {
        $candidates += $existing.Source
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if (-not $candidate) {
            continue
        }
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "lms command was not found. Launch LM Studio once and complete initial setup, then run this script again."
}

function Invoke-Lms {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$CaptureOutput
    )

    $stdoutFile = Join-Path $env:TEMP ("setup_ai_lms_stdout_" + [Guid]::NewGuid().ToString("N") + ".log")
    $stderrFile = Join-Path $env:TEMP ("setup_ai_lms_stderr_" + [Guid]::NewGuid().ToString("N") + ".log")

    try {
        $process = Start-Process -FilePath $script:lmsExe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

        $output = ""
        if ($CaptureOutput) {
            $stdoutText = ""
            $stderrText = ""
            if (Test-Path $stdoutFile) {
                $stdoutText = Get-Content -LiteralPath $stdoutFile -Raw
            }
            if (Test-Path $stderrFile) {
                $stderrText = Get-Content -LiteralPath $stderrFile -Raw
            }
            $output = ($stdoutText + $stderrText).TrimEnd()
        }

        $exitCode = $process.ExitCode
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-LmStudioAppPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\LM Studio\LM Studio.exe")
        (Join-Path $env:ProgramFiles "LM Studio\LM Studio.exe")
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "LM Studio\LM Studio.exe")
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Ensure-LmsServerReady {
    $startResult = Invoke-Lms -Arguments @("server", "start") -CaptureOutput
    if ($startResult.ExitCode -eq 0) {
        return
    }

    if ($startResult.Output -match "no valid installation could be found or installed") {
        $lmStudioExe = Get-LmStudioAppPath
        if ($lmStudioExe) {
            Write-Host "Launching LM Studio for first-time initialization..." -ForegroundColor Yellow
            $appStdout = Join-Path $env:TEMP ("setup_ai_lmstudio_stdout_" + [Guid]::NewGuid().ToString("N") + ".log")
            $appStderr = Join-Path $env:TEMP ("setup_ai_lmstudio_stderr_" + [Guid]::NewGuid().ToString("N") + ".log")
            try {
                Start-Process -FilePath $lmStudioExe -WorkingDirectory (Split-Path -Path $lmStudioExe -Parent) -RedirectStandardOutput $appStdout -RedirectStandardError $appStderr | Out-Null
            }
            catch {
                Start-Process -FilePath $lmStudioExe -WorkingDirectory (Split-Path -Path $lmStudioExe -Parent) | Out-Null
            }
            finally {
                Start-Sleep -Milliseconds 500
                Remove-Item -LiteralPath $appStdout, $appStderr -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Host "Waiting for LM Studio initialization (up to 2 minutes)..." -ForegroundColor Yellow
        $deadline = (Get-Date).AddMinutes(2)
        do {
            Start-Sleep -Seconds 5
            $startResult = Invoke-Lms -Arguments @("server", "start") -CaptureOutput
            if ($startResult.ExitCode -eq 0) {
                return
            }
        } while ((Get-Date) -lt $deadline)

        if ($startResult.Output -match "no valid installation could be found or installed") {
            throw "LM Studio CLI could not locate a valid installation. Open LM Studio once to finish initial setup, then run this script again."
        }
        throw "Failed to start LM Studio local server (lms server start)."
    }

    $maxRetries = 5
    for ($retry = 1; $retry -le $maxRetries; $retry++) {
        Start-Sleep -Seconds 5
        $startResult = Invoke-Lms -Arguments @("server", "start") -CaptureOutput
        if ($startResult.ExitCode -eq 0) {
            return
        }
    }

    throw "Failed to start LM Studio local server (lms server start)."
}

function Normalize-Token([string]$Text) {
    return ([regex]::Replace($Text.ToLowerInvariant(), "[^a-z0-9]", ""))
}

function Get-InstalledModelsText {
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $modelsJson = Invoke-Lms -Arguments @("ls", "--json") -CaptureOutput
        if ($modelsJson.ExitCode -eq 0) {
            return $modelsJson.Output
        }

        $modelsText = Invoke-Lms -Arguments @("ls") -CaptureOutput
        if ($modelsText.ExitCode -eq 0) {
            return $modelsText.Output
        }

        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 2
        }
    }

    throw "Failed to list local models (lms ls)."
}

function Test-ModelInstalled([string]$ModelName, [string]$InstalledModelsText) {
    $normalizedHaystack = Normalize-Token $InstalledModelsText
    $needle = Normalize-Token $ModelName
    return $normalizedHaystack.Contains($needle)
}

function Ensure-ModelInstalled([string]$ModelName) {
    $maxDownloadAttempts = 3
    for ($attempt = 1; $attempt -le $maxDownloadAttempts; $attempt++) {
        $installedModelsText = Get-InstalledModelsText
        if (Test-ModelInstalled -ModelName $ModelName -InstalledModelsText $installedModelsText) {
            if ($attempt -eq 1) {
                Write-Host ("  - " + $ModelName + " is already installed. Skipping.") -ForegroundColor Yellow
            }
            return
        }

        if ($attempt -eq 1) {
            Write-Host ("  - Downloading " + $ModelName + " ...")
        } else {
            Write-Host ("  - Retrying " + $ModelName + " (" + $attempt + "/" + $maxDownloadAttempts + ") ...") -ForegroundColor Yellow
        }

        $downloadResult = Invoke-Lms -Arguments @("get", "--gguf", "-y", $ModelName) -CaptureOutput
        Start-Sleep -Seconds 2
        $installedModelsText = Get-InstalledModelsText
        if (Test-ModelInstalled -ModelName $ModelName -InstalledModelsText $installedModelsText) {
            return
        }

        if ($attempt -lt $maxDownloadAttempts) {
            Start-Sleep -Seconds (5 * $attempt)
            continue
        }

        if ($downloadResult.ExitCode -ne 0) {
            throw ("Model download failed after retries: " + $ModelName)
        }
        throw ("Model download appears incomplete after retries: " + $ModelName)
    }
}

Write-Host "[STEP 1] Initializing winget sources..." -ForegroundColor Cyan
Initialize-WingetSources
Write-Host ""

Write-Host "[STEP 2] Installing LM Studio..." -ForegroundColor Cyan
Ensure-LmStudioInstalled -PackageId $packageId
Write-Host ""

Write-Host "[STEP 3] Refreshing system settings..." -ForegroundColor Cyan
$script:lmsExe = Ensure-LmsCommandReady
Write-Host ("Using lms: " + $script:lmsExe) -ForegroundColor Yellow
Ensure-LmsServerReady
Write-Host ""

Write-Host "[STEP 4] Downloading LLMs..." -ForegroundColor Cyan
Write-Host "This may use huge network data. Please wait." -ForegroundColor Yellow
foreach ($model in $models) {
    Ensure-ModelInstalled -ModelName $model
}
Write-Host ""

Write-Host "===================================================" -ForegroundColor Green
Write-Host "  All setup steps are complete!" -ForegroundColor Green
Write-Host "  Enjoy your local AI tools." -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Green
:__SETUP_AI_PS1_END__
