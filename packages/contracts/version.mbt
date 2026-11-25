///|
/// Product identity shared by the host, the desktop shell and the packaging
/// scripts. The single source of truth for the shipped V0.1 version is the
/// repository `VERSION` file; `scripts/package.sh` verifies the two agree
/// before it produces a tarball.
pub const PRODUCT_NAME : String = "MoNexus"

///|
pub const PRODUCT_VERSION : String = "0.1.0"

///|
/// `monexus-host --version` / `monexus --version` output.
pub fn product_version_line(tool : String) -> String {
  tool + " " + PRODUCT_VERSION + " (" + PRODUCT_NAME + " V0.1)"
}
