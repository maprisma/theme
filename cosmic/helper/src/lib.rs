pub mod automation;
pub mod compositor;
pub mod terminal;
pub mod theme;

use std::{fs::File, io::Read, path::Path};
pub type Result<T> = std::result::Result<T, String>;
pub const MAX_BYTES: u64 = 1024 * 1024;
pub fn read_bounded(path: &Path) -> Result<String> {
    if !std::fs::metadata(path)
        .map_err(|e| e.to_string())?
        .is_file()
    {
        return Err("expected a regular file".into());
    }
    let mut data = Vec::new();
    File::open(path)
        .map_err(|e| e.to_string())?
        .take(MAX_BYTES + 1)
        .read_to_end(&mut data)
        .map_err(|e| e.to_string())?;
    if data.len() as u64 > MAX_BYTES {
        return Err("file exceeds 1 MiB".into());
    }
    String::from_utf8(data).map_err(|e| e.to_string())
}
