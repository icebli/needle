use anyhow::Result;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("serve") => needle_browser_host::serve_queue(),
        Some("discover-serve") => needle_browser_host::discovery::serve_discovery(),
        Some("discover") => {
            needle_browser_host::discovery::run_discovery_command(&args.collect::<Vec<_>>())
        }
        Some("enqueue") => needle_browser_host::run_desktop_command(
            "enqueue",
            std::io::stdin().lock(),
            std::io::stdout().lock(),
        ),
        Some(command @ ("status" | "resume")) => {
            let job_id = args
                .next()
                .ok_or_else(|| anyhow::anyhow!("status requires a job ID"))?;
            needle_browser_host::run_desktop_command(
                command,
                std::io::Cursor::new(job_id),
                std::io::stdout().lock(),
            )
        }
        Some(_) | None => needle_browser_host::run_native_host(),
    }
}
