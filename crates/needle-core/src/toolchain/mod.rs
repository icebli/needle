use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;

/// Discovered external tool paths
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Toolchain {
    pub yt_dlp_path: PathBuf,
    pub ffmpeg_path: PathBuf,
    pub ffprobe_path: PathBuf,
    pub chromaprint_path: Option<PathBuf>,
}

impl Toolchain {
    /// Discover tools from PATH or well-known locations
    pub fn discover() -> Result<Self> {
        let yt_dlp = find_executable("yt-dlp")
            .or_else(|| find_executable("yt-dlp_macos"))
            .ok_or_else(|| anyhow::anyhow!("yt-dlp not found. Install: brew install yt-dlp"))?;

        let ffmpeg = find_executable("ffmpeg")
            .ok_or_else(|| anyhow::anyhow!("ffmpeg not found. Install: brew install ffmpeg"))?;

        let ffprobe = find_executable("ffprobe")
            .ok_or_else(|| anyhow::anyhow!("ffprobe not found (bundled with ffmpeg)"))?;

        let chromaprint = find_executable("fpcalc");

        Ok(Self {
            yt_dlp_path: yt_dlp,
            ffmpeg_path: ffmpeg,
            ffprobe_path: ffprobe,
            chromaprint_path: chromaprint,
        })
    }

    /// Verify each tool works
    pub fn verify(&self) -> Result<Vec<ToolStatus>> {
        let mut results = Vec::new();

        results.push(check_tool("yt-dlp", &self.yt_dlp_path, &["--version"]));
        results.push(check_tool("ffmpeg", &self.ffmpeg_path, &["-version"]));
        results.push(check_tool("ffprobe", &self.ffprobe_path, &["-version"]));

        if let Some(ref cp) = self.chromaprint_path {
            let mut status = check_tool("fpcalc (chromaprint)", cp, &["-version"]);
            status.optional = true;
            results.push(status);
        } else {
            results.push(ToolStatus {
                name: "fpcalc (chromaprint)".into(),
                path: None,
                ok: true,
                optional: true,
                message: "not installed (optional, fingerprint verification unavailable)".into(),
            });
        }

        Ok(results)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolStatus {
    pub name: String,
    pub path: Option<PathBuf>,
    pub ok: bool,
    /// Optional tools can be absent without making the required toolchain fail.
    #[serde(default)]
    pub optional: bool,
    pub message: String,
}

fn find_executable(name: &str) -> Option<PathBuf> {
    which::which(name).ok()
}

fn check_tool(name: &str, path: &PathBuf, args: &[&str]) -> ToolStatus {
    let output = Command::new(path).args(args).output();

    match output {
        Ok(out) if out.status.success() => {
            let ver = String::from_utf8_lossy(&out.stdout)
                .lines()
                .next()
                .unwrap_or("unknown")
                .to_string();
            ToolStatus {
                name: name.into(),
                path: Some(path.clone()),
                ok: true,
                optional: false,
                message: ver,
            }
        }
        Ok(out) => ToolStatus {
            name: name.into(),
            path: Some(path.clone()),
            ok: false,
            optional: false,
            message: format!("exit code: {:?}", out.status.code()),
        },
        Err(e) => ToolStatus {
            name: name.into(),
            path: Some(path.clone()),
            ok: false,
            optional: false,
            message: format!("{e}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_optional_chromaprint_does_not_fail_required_toolchain() {
        let status = Toolchain {
            yt_dlp_path: PathBuf::from("yt-dlp"),
            ffmpeg_path: PathBuf::from("ffmpeg"),
            ffprobe_path: PathBuf::from("ffprobe"),
            chromaprint_path: None,
        };
        let results = status.verify().unwrap();
        let fpcalc = results
            .iter()
            .find(|status| status.name.contains("fpcalc"))
            .unwrap();

        assert!(fpcalc.optional);
        assert!(fpcalc.ok);
        assert!(fpcalc.message.contains("optional"));
    }
}
