//! The portable Windows copy (built with `POLESTAR_PORTABLE=1`, see update.rs `PORTABLE`) keeps
//! everything it writes in one folder beside its .exe, so deleting the .exe and that folder
//! leaves nothing behind:
//!
//! - settings, consent, the upload token and kept guides go to `Polestar Client data\`
//!   instead of `%APPDATA%\gg.polestar.client`;
//! - the WebView2 profile goes to `Polestar Client data\WebView\` instead of
//!   `%LOCALAPPDATA%\gg.polestar.client` (Tauri would otherwise force that folder, so the main
//!   window is taken out of the config and opened here with its own data directory);
//! - `polestar://` links are not registered in the registry (lib.rs `links`), and "Start with my
//!   computer" is hidden and refused (commands.rs, Settings.svelte), since both write to HKCU.

use std::path::PathBuf;

use tauri::utils::config::WindowConfig;
use tauri::{AppHandle, Context, Runtime, WebviewWindowBuilder};

pub use crate::update::PORTABLE as ACTIVE;

/// The folder beside the .exe that holds everything this copy keeps.
pub fn data_dir() -> Result<PathBuf, String> {
	let exe = std::env::current_exe().map_err(|e| format!("Could not find where Polestar Client is: {e}"))?;
	let dir = exe.parent().ok_or("Could not find the folder Polestar Client is in.")?;
	Ok(dir.join("Polestar Client data"))
}

/// The WebView2 profile inside `data`.
pub fn webview_dir(data: &std::path::Path) -> PathBuf {
	data.join("WebView")
}

/// Takes the main window out of the config of a portable build, to be opened by `open_main`
/// with its data directory beside the .exe. `None` (and the config untouched) otherwise.
pub fn take_main<R: Runtime>(context: &mut Context<R>) -> Option<WindowConfig> {
	if !ACTIVE {
		return None;
	}
	let windows = &mut context.config_mut().app.windows;
	let at = windows.iter().position(|w| w.label == "main")?;
	Some(windows.remove(at))
}

/// Opens the main window the config describes, with its WebView2 profile in `webview`.
pub fn open_main<R: Runtime>(app: &AppHandle<R>, config: &WindowConfig, webview: PathBuf) -> tauri::Result<()> {
	WebviewWindowBuilder::from_config(app, config)?.data_directory(webview).build()?;
	Ok(())
}

/// Tells the player why a portable copy cannot start (its folder is not writable, say).
pub fn fail<R: Runtime>(app: &AppHandle<R>, message: &str) {
	use tauri_plugin_dialog::{DialogExt, MessageDialogKind};
	app.dialog()
		.message(message)
		.title("Polestar Client (portable)")
		.kind(MessageDialogKind::Error)
		.blocking_show();
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn keeps_everything_in_one_folder_beside_the_exe() {
		let data = data_dir().unwrap();
		assert_eq!(data.parent(), std::env::current_exe().unwrap().parent());
		assert!(webview_dir(&data).starts_with(&data));
	}
}
