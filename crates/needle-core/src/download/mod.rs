use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;
use tracing::debug;

use crate::toolchain::{yt_dlp_command, yt_dlp_error_message};

/// Immutable plan after candidate selection
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadPlan {
    pub provider: String,
    pub id: String,
    pub url: String,
    pub title: String,
    pub target_format: String,
    pub output_dir: PathBuf,
}

/// Download audio from a candidate URL using yt-dlp
pub fn download_audio(yt_dlp_path: &str, plan: &DownloadPlan) -> Result<PathBuf> {
    download_with_command(yt_dlp_command(yt_dlp_path), plan)
}

fn download_with_command(mut cmd: Command, plan: &DownloadPlan) -> Result<PathBuf> {
    let tmp_dir = &plan.output_dir;
    std::fs::create_dir_all(tmp_dir)?;

    let output_template = tmp_dir.join("source.%(ext)s");
    let output_str = output_template.to_string_lossy();

    debug!("yt-dlp download: {} -> {}", plan.url, output_str);

    let browser_session = cmd.get_args().any(|arg| arg == "--cookies-from-browser");
    cmd.args([
        &plan.url,
        "--extract-audio",
        "--audio-format",
        &plan.target_format,
        "--audio-quality",
        "0",
        "--embed-thumbnail",
        "--no-playlist",
        "--no-warnings",
        "--quiet",
        "--output",
        &output_str,
    ]);
    if !browser_session {
        // Android avoids anonymous web-client media URLs that return 403.
        // With browser cookies, yt-dlp must choose a compatible signed-in client.
        cmd.args(["--extractor-args", "youtube:player_client=android"]);
    }

    // Fixup fixes timestamp/stream issues common on SoundCloud streams
    cmd.arg("--fixup").arg("force");

    let output = cmd.output()?;
    if !output.status.success() {
        bail!(
            "yt-dlp download failed: {}",
            yt_dlp_error_message(&output.stderr)
        );
    }

    // yt-dlp writes e.g. source.webm or source.m4a; find what it produced
    let downloaded = find_downloaded_file(tmp_dir, "source")?;
    Ok(downloaded)
}

/// Convert downloaded audio to target format using ffmpeg
pub fn convert_audio(
    ffmpeg_path: &str,
    input: &Path,
    output: &Path,
    codec: &str,
    bitrate: Option<&str>,
) -> Result<PathBuf> {
    debug!(
        "ffmpeg convert: {} -> {}",
        input.display(),
        output.display()
    );

    let mut cmd = Command::new(ffmpeg_path);
    cmd.args(["-y", "-i", &input.to_string_lossy(), "-c:a", codec]);

    if let Some(br) = bitrate {
        cmd.args(["-b:a", br]);
    }

    cmd.arg("-vn"); // no video
    cmd.arg(&*output.to_string_lossy());

    let result = cmd.output()?;
    if !result.status.success() {
        let stderr = String::from_utf8_lossy(&result.stderr);
        bail!("ffmpeg conversion failed: {}", stderr);
    }

    Ok(output.to_path_buf())
}

/// Find the downloaded audio file in a directory.
///
/// yt-dlp can leave thumbnails or partial files beside the audio. Prefer a
/// known audio extension, then the newest matching file, instead of whichever
/// directory entry happens to come first.
fn find_downloaded_file(dir: &Path, prefix: &str) -> Result<PathBuf> {
    let mut matches = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str.starts_with(prefix) && entry.path().is_file() {
            let modified = entry.metadata().and_then(|meta| meta.modified()).ok();
            matches.push((entry.path(), modified));
        }
    }

    matches.sort_by(|left, right| {
        let left_rank = audio_extension_rank(&left.0);
        let right_rank = audio_extension_rank(&right.0);
        right_rank.cmp(&left_rank).then(right.1.cmp(&left.1))
    });

    matches
        .into_iter()
        .map(|(path, _)| path)
        .next()
        .ok_or_else(|| anyhow::anyhow!("no downloaded file found in {}", dir.display()))
}

fn audio_extension_rank(path: &Path) -> u8 {
    match path
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "mp3" | "m4a" | "opus" | "flac" | "wav" | "ogg" | "webm" | "aac" => 2,
        "part" | "ytdl" | "tmp" | "jpg" | "jpeg" | "png" | "webp" => 0,
        _ => 1,
    }
}

#[cfg(test)]
#[cfg(unix)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn download_uses_android_youtube_client() {
        let root =
            std::env::temp_dir().join(format!("needle-download-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let args_file = root.join("args");
        let script = root.join("fake-yt-dlp");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\ntouch '{}/source.webm'\n",
                args_file.display(),
                root.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

        let plan = DownloadPlan {
            provider: "youtube".into(),
            id: "test".into(),
            url: "https://www.youtube.com/watch?v=test".into(),
            title: "Test".into(),
            target_format: "best".into(),
            output_dir: root.clone(),
        };
        let downloaded = download_with_command(Command::new(&script), &plan).unwrap();
        let args = std::fs::read_to_string(args_file).unwrap();

        assert_eq!(downloaded, root.join("source.webm"));
        assert!(args.contains("--extractor-args\nyoutube:player_client=android\n"));

        let selector = "firefox:/Browser Profile With Spaces";
        let mut command = Command::new(&script);
        command.args(["--cookies-from-browser", selector]);
        let downloaded = download_with_command(command, &plan).unwrap();
        let args = std::fs::read_to_string(root.join("args")).unwrap();
        assert_eq!(downloaded, root.join("source.webm"));
        assert!(args.contains(&format!("--cookies-from-browser\n{selector}\n")));
        assert!(!args.contains("--extractor-args"));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn prefers_audio_over_thumbnail_with_same_prefix() {
        let root =
            std::env::temp_dir().join(format!("needle-download-pick-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("source.jpg"), b"thumb").unwrap();
        std::fs::write(root.join("source.mp3"), b"audio").unwrap();

        let picked = find_downloaded_file(&root, "source").unwrap();

        assert_eq!(picked, root.join("source.mp3"));
        let _ = std::fs::remove_dir_all(root);
    }
}
