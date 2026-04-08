use std::{
    collections::HashSet,
    env,
    io::{self, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const QUESTIONNAIRE_URL: &str = "https://forms.gle/aAFcQ4W4UBrfECZy7";
const PACKAGE_ID: &str = "ElementLabs.LMStudio";
const MODELS: [&str; 3] = [
    "google/gemma-3-4b",
    "openai/gpt-oss-20b",
    "google/gemma-4-31b",
];

#[derive(Debug)]
struct CommandResult {
    exit_code: i32,
    stdout: String,
    stderr: String,
}

impl CommandResult {
    fn success(&self) -> bool {
        self.exit_code == 0
    }

    fn combined_output(&self) -> String {
        let stdout = self.stdout.trim_end();
        let stderr = self.stderr.trim_end();
        if stdout.is_empty() {
            return stderr.to_string();
        }
        if stderr.is_empty() {
            return stdout.to_string();
        }
        format!("{stdout}\n{stderr}")
    }
}

fn run_capture(program: &Path, args: &[&str]) -> Result<CommandResult, String> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("Failed to run {}: {error}", program.display()))?;

    Ok(CommandResult {
        exit_code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

fn run_capture_program(program: &str, args: &[&str]) -> Result<CommandResult, String> {
    run_capture(Path::new(program), args)
}

fn pause_console() {
    print!("Press Enter to exit...");
    let _ = io::stdout().flush();
    let mut line = String::new();
    let _ = io::stdin().read_line(&mut line);
}

fn should_stop_setup() -> Result<bool, String> {
    print!("Stop setup? [Y/n] ");
    io::stdout()
        .flush()
        .map_err(|error| format!("Failed to show prompt: {error}"))?;

    let mut line = String::new();
    io::stdin()
        .read_line(&mut line)
        .map_err(|error| format!("Failed to read response: {error}"))?;
    let input = line.trim().to_ascii_lowercase();
    Ok(input.is_empty() || input == "y" || input == "yes")
}

fn check_winget_available() -> Result<(), String> {
    match run_capture_program("winget", &["--version"]) {
        Ok(result) if result.success() => Ok(()),
        _ => Err(
            "winget was not found.\nPlease update \"App Installer\" in Microsoft Store, then run again."
                .to_string(),
        ),
    }
}

fn initialize_winget_sources() -> Result<(), String> {
    let version = run_capture_program("winget", &["--version"])?;
    if !version.success() {
        return Err("winget failed to start.".to_string());
    }

    let source_list =
        run_capture_program("winget", &["source", "list", "--disable-interactivity"])?;
    if !source_list.success() {
        return Err("winget source list failed.".to_string());
    }

    let source_update =
        run_capture_program("winget", &["source", "update", "--disable-interactivity"])?;
    if !source_update.success() {
        println!(
            "winget source update failed once. Continuing and retrying via install/list commands..."
        );
    }

    Ok(())
}

fn ensure_lm_studio_installed(package_id: &str) -> Result<(), String> {
    let install_args = [
        "install",
        "--id",
        package_id,
        "--exact",
        "--scope",
        "user",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--disable-interactivity",
    ];

    let mut install_output = run_capture_program("winget", &install_args)?;
    if !install_output.success() {
        let _ = run_capture_program("winget", &["source", "update", "--disable-interactivity"]);
        install_output = run_capture_program("winget", &install_args)?;
    }

    if install_output.success() {
        return Ok(());
    }

    let installed_check = run_capture_program(
        "winget",
        &[
            "list",
            "--id",
            package_id,
            "--exact",
            "--accept-source-agreements",
            "--disable-interactivity",
        ],
    )?;
    if installed_check.combined_output().contains(package_id) {
        println!("LM Studio is already installed. Skipping install.");
        return Ok(());
    }

    let output = install_output.combined_output();
    if !output.is_empty() {
        println!("{output}");
    }
    Err("LM Studio installation failed.".to_string())
}

fn ensure_lms_command_ready() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();

    if let Some(local_app_data) = env::var_os("LOCALAPPDATA") {
        candidates.push(
            PathBuf::from(local_app_data)
                .join("Programs")
                .join("LM Studio")
                .join("resources")
                .join("app")
                .join(".webpack")
                .join("lms.exe"),
        );
    }
    if let Some(program_files) = env::var_os("ProgramFiles") {
        candidates.push(
            PathBuf::from(program_files)
                .join("LM Studio")
                .join("resources")
                .join("app")
                .join(".webpack")
                .join("lms.exe"),
        );
    }
    if let Some(program_files_x86) = env::var_os("ProgramFiles(x86)") {
        candidates.push(
            PathBuf::from(program_files_x86)
                .join("LM Studio")
                .join("resources")
                .join("app")
                .join(".webpack")
                .join("lms.exe"),
        );
    }

    if let Ok(where_result) = run_capture_program("where", &["lms"]) {
        if where_result.success() {
            for line in where_result.stdout.lines() {
                let path = line.trim();
                if !path.is_empty() {
                    candidates.push(PathBuf::from(path));
                }
            }
        }
    }

    let mut seen = HashSet::new();
    for candidate in candidates {
        let key = candidate.to_string_lossy().to_ascii_lowercase();
        if !seen.insert(key) {
            continue;
        }
        if candidate.exists() {
            return Ok(candidate);
        }
    }

    Err(
        "lms command was not found. Launch LM Studio once and complete initial setup, then run this script again."
            .to_string(),
    )
}

fn get_lm_studio_app_path() -> Option<PathBuf> {
    let mut candidates = Vec::new();

    if let Some(local_app_data) = env::var_os("LOCALAPPDATA") {
        candidates.push(
            PathBuf::from(local_app_data)
                .join("Programs")
                .join("LM Studio")
                .join("LM Studio.exe"),
        );
    }
    if let Some(program_files) = env::var_os("ProgramFiles") {
        candidates.push(
            PathBuf::from(program_files)
                .join("LM Studio")
                .join("LM Studio.exe"),
        );
    }
    if let Some(program_files_x86) = env::var_os("ProgramFiles(x86)") {
        candidates.push(
            PathBuf::from(program_files_x86)
                .join("LM Studio")
                .join("LM Studio.exe"),
        );
    }

    candidates.into_iter().find(|candidate| candidate.exists())
}

fn invoke_lms(lms_exe: &Path, args: &[&str]) -> Result<CommandResult, String> {
    run_capture(lms_exe, args)
}

fn output_contains(result: &CommandResult, needle: &str) -> bool {
    result
        .combined_output()
        .to_ascii_lowercase()
        .contains(&needle.to_ascii_lowercase())
}

fn launch_lm_studio_for_init(lm_studio_exe: &Path) -> Result<(), String> {
    let mut command = Command::new(lm_studio_exe);
    if let Some(parent) = lm_studio_exe.parent() {
        command.current_dir(parent);
    }

    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("Failed to launch LM Studio for initialization: {error}"))?;

    thread::sleep(Duration::from_millis(500));
    Ok(())
}

fn ensure_lms_server_ready(lms_exe: &Path) -> Result<(), String> {
    let mut start_result = invoke_lms(lms_exe, &["server", "start"])?;
    if start_result.success() {
        return Ok(());
    }

    let missing_installation_text = "no valid installation could be found or installed";
    if output_contains(&start_result, missing_installation_text) {
        if let Some(lm_studio_exe) = get_lm_studio_app_path() {
            println!("Launching LM Studio for first-time initialization...");
            if let Err(error) = launch_lm_studio_for_init(&lm_studio_exe) {
                println!("Warning: {error}");
            }
        }

        println!("Waiting for LM Studio initialization (up to 2 minutes)...");
        let deadline = Instant::now() + Duration::from_secs(120);
        while Instant::now() < deadline {
            thread::sleep(Duration::from_secs(5));
            start_result = invoke_lms(lms_exe, &["server", "start"])?;
            if start_result.success() {
                return Ok(());
            }
        }

        if output_contains(&start_result, missing_installation_text) {
            return Err(
                "LM Studio CLI could not locate a valid installation. Open LM Studio once to finish initial setup, then run this script again."
                    .to_string(),
            );
        }
        return Err("Failed to start LM Studio local server (lms server start).".to_string());
    }

    for _ in 0..5 {
        thread::sleep(Duration::from_secs(5));
        start_result = invoke_lms(lms_exe, &["server", "start"])?;
        if start_result.success() {
            return Ok(());
        }
    }

    Err("Failed to start LM Studio local server (lms server start).".to_string())
}

fn normalize_token(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

fn get_installed_models_text(lms_exe: &Path) -> Result<String, String> {
    for attempt in 1..=3 {
        let models_json = invoke_lms(lms_exe, &["ls", "--json"])?;
        if models_json.success() {
            return Ok(models_json.combined_output());
        }

        let models_text = invoke_lms(lms_exe, &["ls"])?;
        if models_text.success() {
            return Ok(models_text.combined_output());
        }

        if attempt < 3 {
            thread::sleep(Duration::from_secs(2));
        }
    }

    Err("Failed to list local models (lms ls).".to_string())
}

fn test_model_installed(model_name: &str, installed_models_text: &str) -> bool {
    let normalized_haystack = normalize_token(installed_models_text);
    let needle = normalize_token(model_name);
    normalized_haystack.contains(&needle)
}

fn ensure_model_installed(lms_exe: &Path, model_name: &str) -> Result<(), String> {
    let max_download_attempts = 3;

    for attempt in 1..=max_download_attempts {
        let installed_models_text = get_installed_models_text(lms_exe)?;
        if test_model_installed(model_name, &installed_models_text) {
            if attempt == 1 {
                println!("  - {model_name} is already installed. Skipping.");
            }
            return Ok(());
        }

        if attempt == 1 {
            println!("  - Downloading {model_name} ...");
        } else {
            println!("  - Retrying {model_name} ({attempt}/{max_download_attempts}) ...");
        }

        let download_result = invoke_lms(lms_exe, &["get", "--gguf", "-y", model_name])?;
        thread::sleep(Duration::from_secs(2));

        let installed_models_text = get_installed_models_text(lms_exe)?;
        if test_model_installed(model_name, &installed_models_text) {
            return Ok(());
        }

        if attempt < max_download_attempts {
            thread::sleep(Duration::from_secs((5 * attempt) as u64));
            continue;
        }

        if !download_result.success() {
            return Err(format!("Model download failed after retries: {model_name}"));
        }
        return Err(format!(
            "Model download appears incomplete after retries: {model_name}"
        ));
    }

    Ok(())
}

fn open_questionnaire(url: &str) {
    let _ = Command::new("cmd")
        .args(["/C", "start", "", url])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

fn run_setup() -> Result<bool, String> {
    println!("===================================================");
    println!(" [IMPORTANT] Do not use 4G/5G mobile network.");
    println!(" Please run this script on the TUAT campus network.");
    println!("===================================================");
    println!();

    if should_stop_setup()? {
        println!();
        println!("Setup was cancelled.");
        return Ok(false);
    }

    println!();
    check_winget_available()?;

    println!("===================================================");
    println!(" Starting setup for local AI environment.");
    println!(" This may take 10 to 30 minutes.");
    println!("===================================================");
    println!();

    println!("[STEP 1] Initializing winget sources...");
    initialize_winget_sources()?;
    println!();

    println!("[STEP 2] Installing LM Studio...");
    ensure_lm_studio_installed(PACKAGE_ID)?;
    println!();

    println!("[STEP 3] Refreshing system settings...");
    let lms_exe = ensure_lms_command_ready()?;
    println!("Using lms: {}", lms_exe.display());
    ensure_lms_server_ready(&lms_exe)?;
    println!();

    println!("[STEP 4] Downloading LLMs...");
    println!("This may use huge network data. Please wait.");
    for model in MODELS {
        ensure_model_installed(&lms_exe, model)?;
    }
    println!();

    println!("===================================================");
    println!("  All setup steps are complete!");
    println!("  Enjoy your local AI tools.");
    println!("===================================================");
    println!();

    println!("===================================================");
    println!(" Please answer the survey after setup.");
    println!(" URL: {QUESTIONNAIRE_URL}");
    println!("===================================================");
    println!();
    open_questionnaire(QUESTIONNAIRE_URL);

    Ok(true)
}

fn main() {
    match run_setup() {
        Ok(should_pause) => {
            if should_pause {
                pause_console();
            }
        }
        Err(error) => {
            eprintln!();
            eprintln!("[ERROR] {error}");
            eprintln!();
            pause_console();
            std::process::exit(1);
        }
    }
}
