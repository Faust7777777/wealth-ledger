use std::{
    fs::{File, OpenOptions, TryLockError},
    io,
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};

pub(crate) const DEFAULT_LEDGER_LEASE_TIMEOUT: Duration = Duration::from_secs(3);
const LEDGER_LEASE_POLL_INTERVAL: Duration = Duration::from_millis(20);

#[derive(Debug)]
pub(crate) struct LedgerLease {
    _file: File,
    ledger_path: PathBuf,
    lock_path: PathBuf,
}

impl LedgerLease {
    pub(crate) fn ledger_path(&self) -> &Path {
        &self.ledger_path
    }

    pub(crate) fn lock_path(&self) -> &Path {
        &self.lock_path
    }
}

pub(crate) fn acquire_ledger_lease(path: &Path) -> io::Result<LedgerLease> {
    acquire_ledger_lease_with_timeout(path, DEFAULT_LEDGER_LEASE_TIMEOUT)
}

pub(crate) fn acquire_ledger_lease_with_timeout(
    path: &Path,
    timeout: Duration,
) -> io::Result<LedgerLease> {
    let initial_path = normalized_ledger_path(path)?;
    let parent = initial_path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "ledger path must have a parent directory: {}",
                initial_path.display()
            ),
        )
    })?;
    std::fs::create_dir_all(parent)?;

    // Re-normalize after directory creation so aliases through `.` / `..`,
    // symlinks, junctions, and relative paths converge on the same sidecar.
    let ledger_path = normalized_ledger_path(&initial_path)?;
    let lock_path = appended_lock_path(&ledger_path);
    match std::fs::symlink_metadata(&lock_path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.file_type().is_file() => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "ledger lease sidecar must be a regular non-symlink file: {}",
                    lock_path.display()
                ),
            ));
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(contextual_io_error(
                error,
                &lock_path,
                "inspect ledger lease sidecar",
            ));
        }
    }
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .map_err(|error| contextual_io_error(error, &lock_path, "open ledger lease sidecar"))?;

    let started = Instant::now();
    loop {
        match file.try_lock() {
            Ok(()) => {
                return Ok(LedgerLease {
                    _file: file,
                    ledger_path,
                    lock_path,
                });
            }
            Err(TryLockError::WouldBlock) => {
                let elapsed = started.elapsed();
                if elapsed >= timeout {
                    return Err(io::Error::new(
                        io::ErrorKind::WouldBlock,
                        format!(
                            "ledger is already in use; timed out after {} ms waiting for lease: {}",
                            timeout.as_millis(),
                            lock_path.display()
                        ),
                    ));
                }
                thread::sleep(LEDGER_LEASE_POLL_INTERVAL.min(timeout - elapsed));
            }
            Err(TryLockError::Error(error)) => {
                return Err(contextual_io_error(
                    error,
                    &lock_path,
                    "acquire ledger lease",
                ));
            }
        }
    }
}

pub(crate) fn normalized_ledger_path(path: &Path) -> io::Result<PathBuf> {
    if path.as_os_str().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "ledger path must not be empty",
        ));
    }

    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let file_name = absolute.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "ledger path must end with a file name: {}",
                absolute.display()
            ),
        )
    })?;
    let parent = absolute.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "ledger path must have a parent directory: {}",
                absolute.display()
            ),
        )
    })?;

    let normalized_parent = if parent.try_exists()? {
        parent.canonicalize()?
    } else {
        parent.to_path_buf()
    };
    Ok(normalized_parent.join(file_name))
}

fn appended_lock_path(ledger_path: &Path) -> PathBuf {
    let mut lock_path = ledger_path.as_os_str().to_os_string();
    lock_path.push(".lock");
    PathBuf::from(lock_path)
}

fn contextual_io_error(error: io::Error, path: &Path, action: &str) -> io::Error {
    io::Error::new(
        error.kind(),
        format!("failed to {action} at {}: {error}", path.display()),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        sync::atomic::{AtomicU64, Ordering},
    };

    static NEXT_TEST_ID: AtomicU64 = AtomicU64::new(1);
    const SHORT_TIMEOUT: Duration = Duration::from_millis(60);

    struct TestDirectory {
        path: PathBuf,
    }

    impl TestDirectory {
        fn new(label: &str) -> Self {
            let id = NEXT_TEST_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::current_dir()
                .expect("test current directory should exist")
                .join("target")
                .join("ledger_lease_tests")
                .join(format!("{label}_{}_{}", std::process::id(), id));
            fs::create_dir_all(&path).expect("test directory should be created");
            Self { path }
        }

        fn ledger_path(&self) -> PathBuf {
            self.path.join("ledger.json")
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn default_timeout_is_three_seconds() {
        assert_eq!(DEFAULT_LEDGER_LEASE_TIMEOUT, Duration::from_secs(3));
    }

    #[test]
    fn different_ledgers_can_be_leased_concurrently() {
        let directory = TestDirectory::new("different_ledgers");

        let first = acquire_ledger_lease(&directory.path.join("first.json"))
            .expect("first ledger should acquire its lease");
        let second =
            acquire_ledger_lease_with_timeout(&directory.path.join("second.json"), Duration::ZERO)
                .expect("a different ledger should acquire independently");

        assert_ne!(first.lock_path(), second.lock_path());
    }

    #[test]
    fn non_file_sidecar_is_rejected_fail_closed() {
        let directory = TestDirectory::new("non_file_sidecar");
        let ledger_path = directory.ledger_path();
        let lock_path = appended_lock_path(&ledger_path);
        fs::create_dir_all(&lock_path).expect("invalid sidecar directory should be created");

        let error = acquire_ledger_lease_with_timeout(&ledger_path, Duration::ZERO)
            .expect_err("non-file sidecar must be rejected");

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("regular non-symlink file"));
    }

    #[test]
    fn second_handle_times_out_while_first_lease_is_held() {
        let directory = TestDirectory::new("second_handle_timeout");
        let ledger_path = directory.ledger_path();
        let first = acquire_ledger_lease_with_timeout(&ledger_path, SHORT_TIMEOUT)
            .expect("first lease should be acquired");

        let error = acquire_ledger_lease_with_timeout(&ledger_path, SHORT_TIMEOUT)
            .expect_err("second lease should time out");

        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert!(error.to_string().contains("timed out"), "{error}");
        assert_eq!(
            first.ledger_path(),
            normalized_ledger_path(&ledger_path).unwrap()
        );
    }

    #[test]
    fn drop_releases_lock_immediately_and_preserves_sidecar() {
        let directory = TestDirectory::new("drop_release");
        let ledger_path = directory.ledger_path();
        let first = acquire_ledger_lease_with_timeout(&ledger_path, SHORT_TIMEOUT)
            .expect("first lease should be acquired");
        let lock_path = first.lock_path().to_path_buf();
        assert!(lock_path.is_file());

        drop(first);
        let second = acquire_ledger_lease_with_timeout(&ledger_path, Duration::ZERO)
            .expect("lease should be available immediately after drop");

        assert_eq!(second.lock_path(), lock_path);
        assert!(lock_path.is_file());
        drop(second);
        assert!(lock_path.is_file());
    }

    #[test]
    fn relative_parent_alias_conflicts_with_absolute_path() {
        let directory = TestDirectory::new("relative_alias");
        let nested = directory.path.join("nested");
        fs::create_dir_all(&nested).expect("nested alias directory should exist");
        let absolute = directory.ledger_path();
        let relative = absolute
            .strip_prefix(std::env::current_dir().unwrap())
            .expect("test path should be below current directory")
            .parent()
            .unwrap()
            .join("nested")
            .join("..")
            .join("ledger.json");

        let first = acquire_ledger_lease_with_timeout(&relative, SHORT_TIMEOUT)
            .expect("relative alias should acquire the lease");
        let error = acquire_ledger_lease_with_timeout(&absolute, SHORT_TIMEOUT)
            .expect_err("absolute alias must conflict with the held lease");

        assert_eq!(
            first.ledger_path(),
            normalized_ledger_path(&absolute).unwrap()
        );
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
    }
}
