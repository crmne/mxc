use std::env;
use std::fs;
use std::path::PathBuf;

pub fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = rb_sys_env::activate()?;

    if env::var("CARGO_CFG_TARGET_OS")? == "windows" && env::var("CARGO_CFG_TARGET_ENV")? != "msvc"
    {
        stand_in_for_onecore_apiset()?;
    }

    Ok(())
}

// tracelogging, which mxc-sdk uses on Windows, links its ETW functions from
// OneCore_apiset. The MinGW cross-compilers that build the release gems either
// lack that import library or name it in lowercase, which a linker on Linux
// does not match. advapi32 exports the same functions, so an empty archive
// satisfies the -lOneCore_apiset request and advapi32, linked last, provides
// them.
fn stand_in_for_onecore_apiset() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = PathBuf::from(env::var("OUT_DIR")?);
    fs::write(out_dir.join("libOneCore_apiset.a"), b"!<arch>\n")?;
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-arg=-ladvapi32");
    Ok(())
}
