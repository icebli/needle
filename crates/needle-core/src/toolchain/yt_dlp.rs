use std::ffi::OsStr;
use std::process::Command;

/// Build a media request using the browser profile selected by the caller.
pub fn yt_dlp_command(program: impl AsRef<OsStr>) -> Command {
    command_with_browser(
        program.as_ref(),
        std::env::var_os("NEEDLE_COOKIES_FROM_BROWSER").as_deref(),
    )
}

fn command_with_browser(program: &OsStr, browser: Option<&OsStr>) -> Command {
    let mut command = Command::new(program);
    if let Some(browser) = browser.filter(|value| !value.to_string_lossy().trim().is_empty()) {
        command.arg("--cookies-from-browser").arg(browser);
    }
    command
}

/// Keep provider diagnostics actionable without exposing browser data or paths.
pub fn yt_dlp_error_message(stderr: &[u8]) -> &'static str {
    let detail =
        String::from_utf8_lossy(&stderr[stderr.len().saturating_sub(16 * 1024)..]).to_lowercase();
    if detail.contains("cookie")
        && [
            "could not find",
            "could not copy",
            "failed to decrypt",
            "failed to extract",
            "failed to load",
            "unable to open",
            "database is locked",
        ]
        .iter()
        .any(|reason| detail.contains(reason))
    {
        "Could not read the selected browser session. Check the browser profile in Needle Settings, open that browser, then retry."
    } else if [
        "sign in",
        "log in",
        "login required",
        "not a bot",
        "confirm your age",
    ]
    .iter()
    .any(|reason| detail.contains(reason))
    {
        "This source requires a signed-in browser session. Choose a browser profile in Needle Settings, sign in to the provider there, then retry."
    } else if [
        "private video",
        "video unavailable",
        "not available",
        "has been removed",
    ]
    .iter()
    .any(|reason| detail.contains(reason))
    {
        "This recording is unavailable to the selected browser session. Check access in the browser or choose another source."
    } else if detail.contains("unsupported url") {
        "This media URL is not supported by yt-dlp. Choose a supported recording page."
    } else if [
        "timed out",
        "unable to download",
        "http error 429",
        "connection",
    ]
    .iter()
    .any(|reason| detail.contains(reason))
    {
        "The media provider could not be reached. Check the connection and retry."
    } else {
        "The media provider could not complete this request. Retry or choose another recording."
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browser_selector_is_one_literal_argument() {
        let selector = "firefox:/Browser Profiles/zen/Profile With Spaces";
        let command = command_with_browser(OsStr::new("yt-dlp"), Some(OsStr::new(selector)));
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            [OsStr::new("--cookies-from-browser"), OsStr::new(selector)]
        );
    }

    #[test]
    fn anonymous_and_empty_browser_settings_add_no_arguments() {
        for selector in [None, Some(OsStr::new("")), Some(OsStr::new("   "))] {
            let command = command_with_browser(OsStr::new("yt-dlp"), selector);
            assert_eq!(command.get_args().count(), 0);
        }
    }

    #[cfg(unix)]
    #[test]
    fn child_receives_browser_selector_without_shell_splitting() {
        use std::os::unix::fs::PermissionsExt;

        let path = std::env::temp_dir().join(format!("needle-browser-args-{}", std::process::id()));
        std::fs::write(&path, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        let selector = "firefox:/Browser Profile With Spaces/$literal";
        let output = command_with_browser(path.as_os_str(), Some(OsStr::new(selector)))
            .arg("https://www.youtube.com/watch?v=exact-source")
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8(output.stdout).unwrap(),
            format!("--cookies-from-browser\n{selector}\nhttps://www.youtube.com/watch?v=exact-source\n")
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn provider_error_never_includes_browser_details() {
        let error = yt_dlp_error_message(
            b"ERROR: could not find firefox cookies database in /private/profile; secret-cookie=value",
        );
        assert!(error.contains("browser profile"));
        assert!(!error.contains("/private/profile"));
        assert!(!error.contains("secret-cookie"));
    }
}
