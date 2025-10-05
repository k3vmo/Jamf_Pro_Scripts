

#!/bin/bash
#
# Jamf Pro Self Service: Download & Install PKG or DMG from URL
# -------------------------------------------------------------
# Usage in Jamf Pro (Script Parameters):
#   Parameter 4 ($4): Direct URL to .pkg or .dmg
#   Parameter 5 ($5): (Optional) Expected SHA-256 checksum
#   Parameter 6 ($6): (Optional) Human-friendly name to show in logs (e.g., "Google Chrome")
#   Parameter 7 ($7): (Optional) pkg receipt ID or app name (for idempotency)
#                     - For PKG: receipt ID (e.g., "com.google.Chrome")
#                     - For DMG: app name (e.g., "Google Chrome.app")
#   Parameter 8 ($8): (Optional) Minimum macOS version required (e.g., "12.0")
#   Parameter 9 ($9): (Optional) Force file type: "pkg" or "dmg" (if URL lacks extension)
#
# Example PKG:
#   $4 = https://dl.google.com/chrome/mac/universal/stable/gcem/GoogleChrome.pkg
#   $5 = <sha256sum or leave blank>
#   $6 = Google Chrome
#   $7 = com.google.Chrome
#   $8 = 11.0
#
# Example DMG:
#   $4 = https://example.com/SomeApp.dmg
#   $5 = <sha256sum or leave blank>
#   $6 = Some App
#   $7 = Some App.app
#   $8 = 12.0
#
# Exit codes:
#   0 = Success (installed or already present)
#   10 = Missing URL
#   11 = Download failed
#   12 = Checksum mismatch
#   13 = Signature / Gatekeeper validation failed
#   14 = Installer failed
#   15 = OS version too low
#   16 = Unable to mount DMG
#   17 = App not found in DMG
#   18 = Copy to Applications failed
#
set -euo pipefail

JAMF_URL="${4:-}"
EXPECTED_SHA256="${5:-}"
DISPLAY_NAME="${6:-Package}"
IDENTIFIER="${7:-}"
MIN_OS="${8:-}"
FORCE_TYPE="${9:-}"

LOG_FILE="/var/log/jamf_installer.log"
TMP_DIR="$(mktemp -d /private/tmp/jamf_dmg_or_pkg_installer.XXXXXX)"

log() {
	/bin/echo "$(date '+%Y-%m-%d %H:%M:%S') [$DISPLAY_NAME] $*" | /usr/bin/tee -a "$LOG_FILE"
}

cleanup() {
	# Unmount any mounted volumes
	if [[ -n "${MOUNT_POINT:-}" ]] && [[ -d "$MOUNT_POINT" ]]; then
		log "Unmounting $MOUNT_POINT"
		/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet -force 2>/dev/null || true
	fi
	
	if [[ -d "$TMP_DIR" ]]; then
		/bin/rm -rf "$TMP_DIR"
	fi
}
trap cleanup EXIT

# ---------- Preconditions ----------
if [[ -z "$JAMF_URL" ]]; then
	log "ERROR: No URL provided (parameter 4)."
	exit 10
fi

if [[ -n "$MIN_OS" ]]; then
	CURRENT_OS="$(/usr/bin/sw_vers -productVersion)"
	if [[ "$(printf '%s\n%s\n' "$MIN_OS" "$CURRENT_OS" | /usr/bin/sort -V | /usr/bin/head -n1)" != "$MIN_OS" ]]; then
		log "ERROR: macOS $MIN_OS or newer required; current is $CURRENT_OS."
		exit 15
	fi
fi

# ---------- Determine file type ----------
if [[ -n "$FORCE_TYPE" ]]; then
	FILE_TYPE="$FORCE_TYPE"
	log "File type forced to: $FILE_TYPE"
else
	# Extract from URL
	if [[ "$JAMF_URL" =~ \.pkg($|\?) ]]; then
		FILE_TYPE="pkg"
	elif [[ "$JAMF_URL" =~ \.dmg($|\?) ]]; then
		FILE_TYPE="dmg"
	else
		log "ERROR: Unable to determine file type from URL. Use parameter 9 to force type."
		exit 10
	fi
fi

log "Detected file type: $FILE_TYPE"

# Set file path based on type
if [[ "$FILE_TYPE" == "pkg" ]]; then
	DOWNLOAD_PATH="$TMP_DIR/package.pkg"
else
	DOWNLOAD_PATH="$TMP_DIR/package.dmg"
fi

# ---------- Idempotency check ----------
if [[ -n "$IDENTIFIER" ]]; then
	if [[ "$FILE_TYPE" == "pkg" ]]; then
		# Check for pkg receipt
		if /usr/sbin/pkgutil --pkgs | /usr/bin/grep -qE "^${IDENTIFIER}$"; then
			log "Package already installed (receipt: $IDENTIFIER). Nothing to do."
			exit 0
		fi
	else
		# Check if app exists in /Applications
		if [[ -d "/Applications/$IDENTIFIER" ]]; then
			log "Application already installed: /Applications/$IDENTIFIER. Nothing to do."
			exit 0
		fi
	fi
fi

# ---------- Download ----------
log "Downloading $FILE_TYPE from: $JAMF_URL"
if ! /usr/bin/curl -L --fail --show-error --retry 3 --connect-timeout 20 -o "$DOWNLOAD_PATH" "$JAMF_URL"; then
	log "ERROR: Download failed."
	exit 11
fi

if [[ ! -s "$DOWNLOAD_PATH" ]]; then
	log "ERROR: Downloaded file is empty or missing."
	exit 11
fi

# ---------- Optional checksum ----------
if [[ -n "$EXPECTED_SHA256" ]]; then
	ACTUAL_SHA256="$(/sbin/shasum -a 256 "$DOWNLOAD_PATH" | /usr/bin/awk '{print $1}')"
	if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
		log "ERROR: SHA-256 mismatch."
		log "Expected: $EXPECTED_SHA256"
		log "Actual:   $ACTUAL_SHA256"
		exit 12
	else
		log "Checksum verified (SHA-256)."
	fi
else
	log "No checksum provided; skipping verification."
fi

# ---------- Installation based on file type ----------
if [[ "$FILE_TYPE" == "pkg" ]]; then
	# ---------- PKG Installation ----------
	
	# Optional signature / Gatekeeper validation
	if /usr/sbin/spctl -a -vv -t install "$DOWNLOAD_PATH" >/dev/null 2>&1; then
		log "Gatekeeper validation passed."
	else
		log "WARNING: Gatekeeper validation did not pass. Proceeding with install."
	fi
	
	log "Installing $DISPLAY_NAME ..."
	if /usr/sbin/installer -pkg "$DOWNLOAD_PATH" -target / -verboseR; then
		log "Install complete."
	else
		log "ERROR: Installer failed."
		exit 14
	fi
	
	# Post-check (receipt)
	if [[ -n "$IDENTIFIER" ]]; then
		if /usr/sbin/pkgutil --pkgs | /usr/bin/grep -qE "^${IDENTIFIER}$"; then
			log "Verified receipt present: $IDENTIFIER"
		else
			log "WARNING: Receipt $IDENTIFIER not found after install."
		fi
	fi
	
else
	# ---------- DMG Installation ----------
	
	log "Mounting DMG..."
	MOUNT_OUTPUT="$(/usr/bin/hdiutil attach "$DOWNLOAD_PATH" -nobrowse -noverify -noautoopen 2>&1)"
	
	if [[ $? -ne 0 ]]; then
		log "ERROR: Failed to mount DMG."
		log "$MOUNT_OUTPUT"
		exit 16
	fi
	
	# Extract mount point from hdiutil output
	MOUNT_POINT="$(echo "$MOUNT_OUTPUT" | /usr/bin/grep '/Volumes/' | /usr/bin/awk -F '\t' '{print $NF}' | /usr/bin/tail -1)"
	
	if [[ -z "$MOUNT_POINT" ]] || [[ ! -d "$MOUNT_POINT" ]]; then
		log "ERROR: Could not determine mount point."
		exit 16
	fi
	
	log "DMG mounted at: $MOUNT_POINT"
	
	# Find .app in mounted DMG
	if [[ -n "$IDENTIFIER" ]] && [[ -d "$MOUNT_POINT/$IDENTIFIER" ]]; then
		APP_PATH="$MOUNT_POINT/$IDENTIFIER"
	else
		# Search for any .app
		APP_PATH="$(/usr/bin/find "$MOUNT_POINT" -maxdepth 2 -name "*.app" -type d | /usr/bin/head -1)"
	fi
	
	if [[ -z "$APP_PATH" ]] || [[ ! -d "$APP_PATH" ]]; then
		log "ERROR: No application found in DMG."
		exit 17
	fi
	
	APP_NAME="$(basename "$APP_PATH")"
	log "Found application: $APP_NAME"
	
	# Remove existing app if present
	if [[ -d "/Applications/$APP_NAME" ]]; then
		log "Removing existing version from /Applications..."
		/bin/rm -rf "/Applications/$APP_NAME"
	fi
	
	# Copy to /Applications
	log "Copying $APP_NAME to /Applications..."
	if /bin/cp -R "$APP_PATH" /Applications/; then
		log "Successfully copied to /Applications/$APP_NAME"
	else
		log "ERROR: Failed to copy application to /Applications."
		exit 18
	fi
	
	# Verify installation
	if [[ -d "/Applications/$APP_NAME" ]]; then
		log "Installation verified: /Applications/$APP_NAME"
	else
		log "WARNING: Application not found in /Applications after copy."
	fi
	
	# Clear quarantine attribute
	log "Clearing quarantine attributes..."
	/usr/bin/xattr -dr com.apple.quarantine "/Applications/$APP_NAME" 2>/dev/null || true
	
	log "Install complete."
fi

exit 0
