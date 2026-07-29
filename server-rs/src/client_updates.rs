use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{env, path::PathBuf};
use tokio::fs::File;

const SHA256_HEX_LENGTH: usize = 64;

#[derive(Clone)]
pub struct ClientUpdateStore {
    root: Option<PathBuf>,
}

pub struct UpdateManifest {
    pub bytes: Vec<u8>,
    pub etag: String,
}

pub struct UpdateAsset {
    pub file: File,
    pub size: u64,
    pub sha256: String,
    pub content_type: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ClientUpdateError {
    InvalidPath,
    NotConfigured,
    NotFound,
    InvalidManifest,
    Io,
}

impl ClientUpdateStore {
    pub fn from_env() -> Self {
        Self::new(
            env::var("FINWEALTH_CLIENT_UPDATE_DIR")
                .ok()
                .map(PathBuf::from),
        )
    }

    pub fn new(root: Option<PathBuf>) -> Self {
        Self { root }
    }

    pub async fn latest(
        &self,
        platform: &str,
        channel: &str,
    ) -> Result<UpdateManifest, ClientUpdateError> {
        validate_platform_channel(platform, channel)?;
        let root = self.root.as_ref().ok_or(ClientUpdateError::NotConfigured)?;
        let path = root.join(platform).join(channel).join("latest.json");
        let bytes = tokio::fs::read(path).await.map_err(map_io_error)?;
        let value: Value =
            serde_json::from_slice(&bytes).map_err(|_| ClientUpdateError::InvalidManifest)?;
        validate_manifest(&value, platform, channel)?;
        let etag = format!("\"{}\"", hex_sha256(&bytes));
        Ok(UpdateManifest { bytes, etag })
    }

    pub async fn asset(
        &self,
        platform: &str,
        channel: &str,
        file_name: &str,
    ) -> Result<UpdateAsset, ClientUpdateError> {
        validate_platform_channel(platform, channel)?;
        validate_file_name(platform, file_name)?;
        let root = self.root.as_ref().ok_or(ClientUpdateError::NotConfigured)?;
        let releases = root.join(platform).join(channel).join("releases");
        let path = releases.join(file_name);
        let sidecar_path = releases.join(format!("{file_name}.sha256"));
        let sidecar = tokio::fs::read_to_string(sidecar_path)
            .await
            .map_err(map_io_error)?;
        let sha256 = parse_sha256_sidecar(&sidecar, file_name)?;
        let file = File::open(&path).await.map_err(map_io_error)?;
        let metadata = file.metadata().await.map_err(|_| ClientUpdateError::Io)?;
        if !metadata.is_file() {
            return Err(ClientUpdateError::NotFound);
        }
        let content_type = match platform {
            "android" => "application/vnd.android.package-archive",
            "windows" => "application/zip",
            _ => return Err(ClientUpdateError::InvalidPath),
        };
        Ok(UpdateAsset {
            file,
            size: metadata.len(),
            sha256,
            content_type,
        })
    }
}

fn validate_platform_channel(platform: &str, channel: &str) -> Result<(), ClientUpdateError> {
    if !matches!(platform, "android" | "windows") || !valid_segment(channel, 32) {
        return Err(ClientUpdateError::InvalidPath);
    }
    Ok(())
}

fn valid_segment(value: &str, max_len: usize) -> bool {
    !value.is_empty()
        && value.len() <= max_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn validate_file_name(platform: &str, file_name: &str) -> Result<(), ClientUpdateError> {
    let extension_matches = match platform {
        "android" => file_name.ends_with(".apk"),
        "windows" => file_name.ends_with(".zip"),
        _ => false,
    };
    if file_name.is_empty()
        || file_name.len() > 180
        || !extension_matches
        || !file_name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-'))
    {
        return Err(ClientUpdateError::InvalidPath);
    }
    Ok(())
}

fn validate_manifest(
    value: &Value,
    platform: &str,
    channel: &str,
) -> Result<(), ClientUpdateError> {
    let object = value
        .as_object()
        .ok_or(ClientUpdateError::InvalidManifest)?;
    let allowed_fields = [
        "schemaVersion",
        "platform",
        "channel",
        "versionName",
        "versionCode",
        "releasedAt",
        "sourceCommit",
        "mandatory",
        "minimumVersionCode",
        "notes",
        "asset",
    ];
    if object.len() != allowed_fields.len()
        || object
            .keys()
            .any(|key| !allowed_fields.contains(&key.as_str()))
    {
        return Err(ClientUpdateError::InvalidManifest);
    }
    let version_code = object
        .get("versionCode")
        .and_then(Value::as_u64)
        .filter(|value| *value > 0)
        .ok_or(ClientUpdateError::InvalidManifest)?;
    let minimum_version_code = object
        .get("minimumVersionCode")
        .and_then(Value::as_u64)
        .filter(|value| *value > 0 && *value <= version_code)
        .ok_or(ClientUpdateError::InvalidManifest)?;
    let notes_are_valid = object
        .get("notes")
        .and_then(Value::as_array)
        .is_some_and(|notes| {
            notes.len() <= 20
                && notes.iter().all(|note| {
                    note.as_str()
                        .is_some_and(|text| !text.is_empty() && text.chars().count() <= 240)
                })
        });
    if object.get("schemaVersion").and_then(Value::as_u64) != Some(1)
        || object.get("platform").and_then(Value::as_str) != Some(platform)
        || object.get("channel").and_then(Value::as_str) != Some(channel)
        || !object
            .get("versionName")
            .and_then(Value::as_str)
            .is_some_and(|text| !text.is_empty() && text.len() <= 64)
        || version_code == 0
        || minimum_version_code == 0
        || object
            .get("releasedAt")
            .and_then(Value::as_str)
            .is_none_or(|text| text.is_empty())
        || object.get("mandatory").and_then(Value::as_bool).is_none()
        || !notes_are_valid
        || !object
            .get("sourceCommit")
            .and_then(Value::as_str)
            .is_some_and(valid_sha256_like_commit)
    {
        return Err(ClientUpdateError::InvalidManifest);
    }
    let asset = object
        .get("asset")
        .and_then(Value::as_object)
        .ok_or(ClientUpdateError::InvalidManifest)?;
    let allowed_asset_fields = ["url", "fileName", "sizeBytes", "sha256", "contentType"];
    if asset.len() != allowed_asset_fields.len()
        || asset
            .keys()
            .any(|key| !allowed_asset_fields.contains(&key.as_str()))
    {
        return Err(ClientUpdateError::InvalidManifest);
    }
    let file_name = asset
        .get("fileName")
        .and_then(Value::as_str)
        .ok_or(ClientUpdateError::InvalidManifest)?;
    validate_file_name(platform, file_name).map_err(|_| ClientUpdateError::InvalidManifest)?;
    let expected_url = format!("/v1/client-updates/{platform}/{channel}/assets/{file_name}");
    if asset.get("url").and_then(Value::as_str) != Some(expected_url.as_str())
        || !asset
            .get("sha256")
            .and_then(Value::as_str)
            .is_some_and(valid_sha256)
        || asset.get("sizeBytes").and_then(Value::as_u64).is_none()
        || asset.get("sizeBytes").and_then(Value::as_u64) == Some(0)
        || asset.get("contentType").and_then(Value::as_str)
            != Some(match platform {
                "android" => "application/vnd.android.package-archive",
                "windows" => "application/zip",
                _ => return Err(ClientUpdateError::InvalidManifest),
            })
    {
        return Err(ClientUpdateError::InvalidManifest);
    }
    Ok(())
}

fn valid_sha256_like_commit(value: &str) -> bool {
    value.len() == 40
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_sha256(value: &str) -> bool {
    value.len() == SHA256_HEX_LENGTH
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn parse_sha256_sidecar(
    value: &str,
    expected_file_name: &str,
) -> Result<String, ClientUpdateError> {
    let mut parts = value.split_whitespace();
    let sha256 = parts.next().ok_or(ClientUpdateError::InvalidManifest)?;
    let file_name = parts.next().ok_or(ClientUpdateError::InvalidManifest)?;
    if parts.next().is_some() || !valid_sha256(sha256) || file_name != expected_file_name {
        return Err(ClientUpdateError::InvalidManifest);
    }
    Ok(sha256.to_ascii_lowercase())
}

fn hex_sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn map_io_error(error: std::io::Error) -> ClientUpdateError {
    if error.kind() == std::io::ErrorKind::NotFound {
        ClientUpdateError::NotFound
    } else {
        ClientUpdateError::Io
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, time::SystemTime};

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let suffix = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = env::temp_dir().join(format!("finwealth-update-{suffix}"));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn manifest(file_name: &str, size: u64, sha256: &str) -> Value {
        serde_json::json!({
            "schemaVersion": 1,
            "platform": "android",
            "channel": "stable",
            "versionName": "1.1.0",
            "versionCode": 2,
            "releasedAt": "2026-07-28T12:00:00Z",
            "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
            "mandatory": false,
            "minimumVersionCode": 1,
            "notes": ["应用内更新"],
            "asset": {
                "url": format!("/v1/client-updates/android/stable/assets/{file_name}"),
                "fileName": file_name,
                "sizeBytes": size,
                "sha256": sha256,
                "contentType": "application/vnd.android.package-archive"
            }
        })
    }

    #[tokio::test]
    async fn reads_valid_manifest_and_asset() {
        let temp = TempDir::new();
        let channel = temp.0.join("android/stable");
        let releases = channel.join("releases");
        fs::create_dir_all(&releases).unwrap();
        let file_name = "finwealth-1.1.0-android.apk";
        let bytes = b"apk-fixture";
        let sha256 = hex_sha256(bytes);
        fs::write(
            channel.join("latest.json"),
            manifest(file_name, 11, &sha256).to_string(),
        )
        .unwrap();
        fs::write(releases.join(file_name), bytes).unwrap();
        fs::write(
            releases.join(format!("{file_name}.sha256")),
            format!("{sha256}  {file_name}\n"),
        )
        .unwrap();

        let store = ClientUpdateStore::new(Some(temp.0.clone()));
        let latest = store.latest("android", "stable").await.unwrap();
        assert!(!latest.bytes.is_empty());
        assert!(latest.etag.starts_with('"'));
        let asset = store.asset("android", "stable", file_name).await.unwrap();
        assert_eq!(asset.size, 11);
        assert_eq!(asset.sha256, sha256);
    }

    #[tokio::test]
    async fn rejects_traversal_and_invalid_manifest_url() {
        let store = ClientUpdateStore::new(Some(PathBuf::from("unused")));
        assert_eq!(
            store.asset("android", "../stable", "app.apk").await.err(),
            Some(ClientUpdateError::InvalidPath)
        );
        assert_eq!(
            store
                .asset("android", "stable", "../secret.apk")
                .await
                .err(),
            Some(ClientUpdateError::InvalidPath)
        );

        let mut value = manifest(
            "app.apk",
            1,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        );
        value["asset"]["url"] = Value::String("https://example.invalid/app.apk".into());
        assert_eq!(
            validate_manifest(&value, "android", "stable"),
            Err(ClientUpdateError::InvalidManifest)
        );
    }
}
