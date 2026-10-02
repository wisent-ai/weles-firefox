//! `weles-firefox package`: sign a copy of an existing Firefox build before
//! archiving and hashing it as a Weles browser candidate. The input
//! application is never launched or modified.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

#[derive(Parser)]
#[command(
    about = "Package an existing Firefox build without launching or modifying it",
    after_help = "Exit 2: the invocation is wrong; exit 1: the input, the signature or the output refused, with the reason on stderr."
)]
struct Cli {
    #[command(subcommand)]
    command: Action,
}

#[derive(Subcommand)]
enum Action {
    /// Sign a copied Firefox app before archiving and hashing.
    Package {
        /// The Firefox .app to package; it is copied, never launched or changed.
        #[arg(long)]
        app: PathBuf,
        /// Candidate version, `<upstream>-weles.N`.
        #[arg(long)]
        version: String,
        /// Directory the candidate directory is created in.
        #[arg(long, default_value = concat!(env!("CARGO_MANIFEST_DIR"), "/artifacts"))]
        output: PathBuf,
        /// Print the candidate as JSON instead of `field: value` lines.
        #[arg(long)]
        json: bool,
    },
}

fn command(program: &str, args: &[&str], cwd: Option<&Path>) -> Result<String> {
    let mut run = Command::new(program);
    run.args(args);
    if let Some(cwd) = cwd {
        run.current_dir(cwd);
    }
    let out = run.output().with_context(|| format!("start {program}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        let said = if stderr.is_empty() { stdout } else { stderr };
        bail!("{program} failed ({}): {said}", out.status);
    }
    Ok(stdout)
}

fn digest(path: &Path) -> Result<String> {
    let bytes = fs::read(path).with_context(|| format!("read {}", path.display()))?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

/// `<upstream>-weles.N` with N a positive integer without a leading zero.
fn valid_version(version: &str, upstream: &str) -> bool {
    version
        .strip_prefix(upstream)
        .and_then(|rest| rest.strip_prefix("-weles."))
        .is_some_and(|n| {
            !n.is_empty() && !n.starts_with('0') && n.bytes().all(|b| b.is_ascii_digit())
        })
}

fn valid_identifier(identifier: &str) -> bool {
    identifier.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && identifier
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// What the input application declares about itself.
struct Input {
    app: PathBuf,
    identifier: String,
    executable_sha256: String,
}

fn read_input(app: &Path, upstream: &str) -> Result<Input> {
    let app = fs::canonicalize(app).with_context(|| format!("{} does not exist", app.display()))?;
    let info: plist::Dictionary = plist::from_file(app.join("Contents/Info.plist"))?;
    let text = |key: &str| info.get(key).and_then(plist::Value::as_string).unwrap_or("");
    if text("CFBundleExecutable") != "firefox" || text("CFBundleShortVersionString") != upstream {
        bail!("input must be a Firefox {upstream} application");
    }
    let identifier = text("CFBundleIdentifier").to_string();
    if !valid_identifier(&identifier) {
        bail!("Firefox application has no valid CFBundleIdentifier");
    }
    let executable_sha256 = digest(&app.join("Contents/MacOS/firefox"))?;
    Ok(Input { app, identifier, executable_sha256 })
}

/// Copy, sign and verify the app, then archive it into `work/published`.
/// Answers the archive's file name and the signing record without its state.
fn stage(work: &Path, input: &Input, version: &str, platform: &str) -> Result<(String, Value)> {
    let staged = work.join("Firefox.app");
    command(
        "/bin/cp",
        &["-R", &input.app.to_string_lossy(), &staged.to_string_lossy()],
        None,
    )?;
    let staged_text = staged.to_string_lossy().to_string();
    let signed = command(
        "stado",
        &["product", "signing", "sign", "--identifier", &input.identifier, &staged_text, "--json"],
        None,
    )?;
    let mut signing: Value = serde_json::from_str::<Value>(&signed)?[0].take();
    if signing["state"] != "stable" {
        bail!("Firefox signature is not stable: {signing}");
    }
    if let Some(record) = signing.as_object_mut() {
        record.remove("state");
    }
    command(
        "/usr/bin/codesign",
        &["--verify", "--deep", "--strict", "-R", "=anchor apple generic", &staged_text],
        None,
    )?;
    let published = work.join("published");
    fs::create_dir(&published)?;
    let artifact = format!("weles-firefox-{version}-{platform}.tar.gz");
    let file = fs::File::create(published.join(&artifact))?;
    let encoder = flate2::write::GzEncoder::new(file, flate2::Compression::default());
    let mut archive = tar::Builder::new(encoder);
    archive.follow_symlinks(false);
    archive.append_dir_all("Firefox.app", &staged)?;
    archive.into_inner()?.finish()?;
    Ok((artifact, signing))
}

fn package(app: &Path, version: &str, output: &Path) -> Result<Value> {
    if !cfg!(target_os = "macos") {
        bail!("Apple-signed Firefox packaging requires macOS");
    }
    let platform = match std::env::consts::ARCH {
        "aarch64" => "darwin-arm64",
        "x86_64" => "darwin-x64",
        other => bail!("unsupported macOS architecture: {other}"),
    };
    let root = Path::new(ROOT);
    let capabilities = root.join("browser-capabilities.json");
    let declared: Value = serde_json::from_slice(&fs::read(&capabilities)?)?;
    let upstream = declared["upstreamVersion"].as_str().context("upstreamVersion")?;
    if !valid_version(version, upstream) {
        bail!("version must be {upstream}-weles.N with N greater than zero");
    }
    let input = read_input(app, upstream)?;
    let revision = command("git", &["rev-parse", "HEAD"], Some(root))?;
    let dirty = command("git", &["status", "--porcelain", "--untracked-files=normal"], Some(root))?;
    if !dirty.is_empty() {
        bail!("commit Firefox packaging inputs before creating a candidate");
    }
    let patch_tree = command("git", &["rev-parse", "HEAD:patches"], Some(root))?;
    let candidate = format!("candidate-firefox-{version}-{}", &revision[..8]);
    fs::create_dir_all(output)?;
    let output = fs::canonicalize(output)?;
    let destination = output.join(format!("{candidate}-{platform}"));
    if destination.exists() {
        bail!("candidate output already exists: {}", destination.display());
    }
    let work = output.join(format!(".candidate-{}", std::process::id()));
    fs::create_dir(&work)?;
    let result = (|| -> Result<Value> {
        let (artifact, signature) = stage(&work, &input, version, platform)?;
        let published = work.join("published");
        let artifact_sha = digest(&published.join(&artifact))?;
        let sums = format!("{artifact_sha}  {artifact}\n");
        fs::write(published.join(format!("{artifact}.sha256")), sums)?;
        let metadata = json!({
            "schema": "weles.browser-candidate.v1", "engine": "firefox",
            "finalTag": format!("firefox-{version}"), "candidateTag": candidate,
            "sourceRevision": revision, "patchTree": patch_tree, "platform": platform,
            "entrypoint": "Firefox.app/Contents/MacOS/firefox", "artifact": artifact,
            "artifactSha256": artifact_sha, "capabilitiesSha256": digest(&capabilities)?,
            "status": "candidate", "inputExecutableSha256": input.executable_sha256,
            "codeSignature": signature,
        });
        let text = serde_json::to_string_pretty(&metadata)? + "\n";
        fs::write(published.join("release-metadata.json"), text)?;
        fs::copy(&capabilities, published.join("browser-capabilities.release.json"))?;
        if destination.exists() {
            bail!("candidate output already exists: {}", destination.display());
        }
        fs::rename(&published, &destination)?;
        let mut answer = metadata;
        answer["directory"] = json!(destination.display().to_string());
        Ok(answer)
    })();
    let _ = fs::remove_dir_all(&work);
    result
}

fn main() {
    let Action::Package { app, version, output, json } = Cli::parse().command;
    match package(&app, &version, &output) {
        Ok(answer) if json => println!("{}", serde_json::to_string_pretty(&answer).unwrap_or_default()),
        Ok(answer) => {
            // The same candidate as `field: value` lines (cli.md rule 13); the
            // nested code signature prints as one JSON value.
            for (field, value) in answer.as_object().into_iter().flatten() {
                match value.as_str() {
                    Some(text) => println!("{field}: {text}"),
                    None => println!("{field}: {value}"),
                }
            }
        }
        Err(error) => {
            eprintln!("Error: {error:#}");
            std::process::exit(1);
        }
    }
}
