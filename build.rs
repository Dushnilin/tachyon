use std::path::Path;
use std::process::Command;

fn valid_hex_sha(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if (7..=40).contains(&trimmed.len()) && trimmed.bytes().all(|b| b.is_ascii_hexdigit()) {
        Some(trimmed.to_ascii_lowercase())
    } else {
        None
    }
}

fn main() {
    println!("cargo:rerun-if-env-changed=TACHYON_BUILD_COMMIT");

    let git_dir = Path::new(".git");
    if git_dir.is_dir() {
        let head_path = git_dir.join("HEAD");
        if head_path.is_file() {
            println!("cargo:rerun-if-changed=.git/HEAD");
            if let Ok(head_raw) = std::fs::read_to_string(&head_path)
                && let Some(rel_ref) = head_raw.trim().strip_prefix("ref:")
            {
                let rel = rel_ref.trim();
                if !rel.is_empty() && git_dir.join(rel).exists() {
                    println!("cargo:rerun-if-changed=.git/{rel}");
                }
            }
        }
    }

    let env_sha = std::env::var("TACHYON_BUILD_COMMIT")
        .ok()
        .and_then(|v| valid_hex_sha(&v));

    let sha = env_sha.or_else(|| {
        Command::new("git")
            .args(["rev-parse", "HEAD"])
            .output()
            .ok()
            .filter(|out| out.status.success())
            .and_then(|out| valid_hex_sha(&String::from_utf8_lossy(&out.stdout)))
    });

    if let Some(clean_sha) = sha {
        println!("cargo:rustc-env=TACHYON_BUILD_COMMIT={clean_sha}");
    }
}
