#!/bin/bash

################################################################################
# App Auto Patch & Installomator Uninstaller for macOS
# 
# This script removes:
# - App Auto Patch (all components)
# - Installomator (all components)
# - Related LaunchDaemons, preferences, and files
#
# This script PRESERVES:
# - swiftDialog (left intact)
#
# Usage: sudo ./uninstall_aap_installomator.sh
################################################################################

# Script variables
SCRIPT_NAME="App Auto Patch & Installomator Uninstaller"
SCRIPT_VERSION="1.0"
LOG_FILE="/var/log/app_auto_patch_uninstall_$(date +%Y%m%d_%H%M%S).log"

# App Auto Patch locations
AAP_MAIN_DIR="/Library/Management/AppAutoPatch"
AAP_LAUNCHDAEMON="/Library/LaunchDaemons/com.app.autopatch.plist"
AAP_LAUNCHDAEMON_ALT="/Library/LaunchDaemons/com.secondsonconsulting.appautopatch.plist"
AAP_SYMLINK="/usr/local/bin/appautopatch"
AAP_LOCAL_PLIST="/Library/Preferences/com.secondsonconsulting.appautopatch.plist"
AAP_PROFILE_ID="com.secondsonconsulting.appautopatch"

# Installomator locations
INSTALLOMATOR_SCRIPT="/usr/local/Installomator/Installomator.sh"
INSTALLOMATOR_DIR="/usr/local/Installomator"
INSTALLOMATOR_SYMLINK="/usr/local/bin/installomator"

# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

################################################################################
# Functions
################################################################################

# Logging function
log_message() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    log_message "INFO" "$@"
    echo -e "${BLUE}[INFO]${NC} $@"
}

log_success() {
    log_message "SUCCESS" "$@"
    echo -e "${GREEN}[SUCCESS]${NC} $@"
}

log_warning() {
    log_message "WARNING" "$@"
    echo -e "${YELLOW}[WARNING]${NC} $@"
}

log_error() {
    log_message "ERROR" "$@"
    echo -e "${RED}[ERROR]${NC} $@"
}

log_skip() {
    log_message "SKIP" "$@"
    echo -e "${CYAN}[SKIP]${NC} $@"
}

# Print header
print_header() {
    echo ""
    echo "=============================================================================="
    echo "  ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "=============================================================================="
    echo ""
    echo -e "${YELLOW}This script will remove:${NC}"
    echo "  - App Auto Patch (complete removal)"
    echo "  - Installomator (complete removal)"
    echo ""
    echo -e "${GREEN}This script will preserve:${NC}"
    echo "  - swiftDialog (will NOT be removed)"
    echo ""
    echo "Log file: ${LOG_FILE}"
    echo ""
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        echo ""
        echo "Usage: sudo $0"
        exit 1
    fi
}

# Confirm with user
confirm_uninstall() {
    echo -ne "${YELLOW}Do you want to proceed with uninstallation? (yes/no): ${NC}"
    read -r response
    
    if [[ ! "${response}" =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Uninstallation cancelled by user"
        exit 0
    fi
    echo ""
}

# Stop and unload LaunchDaemon
stop_launchdaemon() {
    local plist=$1
    local daemon_name=$(basename "${plist}" .plist)
    
    if [[ -f "${plist}" ]]; then
        log_info "Found LaunchDaemon: ${plist}"
        
        # Check if daemon is loaded
        if launchctl list | grep -q "${daemon_name}"; then
            log_info "Stopping LaunchDaemon: ${daemon_name}"
            
            # Try modern bootout command first (macOS 10.11+)
            if launchctl bootout system "${plist}" 2>/dev/null; then
                log_success "Successfully stopped LaunchDaemon: ${daemon_name}"
            # Fall back to legacy unload command
            elif launchctl unload -w "${plist}" 2>/dev/null; then
                log_success "Successfully stopped LaunchDaemon: ${daemon_name}"
            else
                log_warning "Could not stop LaunchDaemon (may already be stopped): ${daemon_name}"
            fi
            
            # Give it a moment to fully stop
            sleep 1
        else
            log_info "LaunchDaemon not currently loaded: ${daemon_name}"
        fi
        
        # Remove the plist file
        log_info "Removing LaunchDaemon plist: ${plist}"
        if rm -f "${plist}"; then
            log_success "Removed: ${plist}"
        else
            log_error "Failed to remove: ${plist}"
        fi
    else
        log_info "LaunchDaemon not found: ${plist}"
    fi
}

# Remove directory
remove_directory() {
    local dir=$1
    local description=$2
    
    if [[ -d "${dir}" ]]; then
        log_info "Removing ${description}: ${dir}"
        
        # Get directory size before removal
        local size=$(du -sh "${dir}" 2>/dev/null | awk '{print $1}')
        
        if rm -rf "${dir}"; then
            log_success "Removed ${description} (freed ${size}): ${dir}"
        else
            log_error "Failed to remove ${description}: ${dir}"
            return 1
        fi
    else
        log_info "${description} not found: ${dir}"
    fi
    return 0
}

# Remove file
remove_file() {
    local file=$1
    local description=$2
    
    if [[ -f "${file}" ]]; then
        log_info "Removing ${description}: ${file}"
        if rm -f "${file}"; then
            log_success "Removed: ${file}"
        else
            log_error "Failed to remove: ${file}"
            return 1
        fi
    elif [[ -L "${file}" ]]; then
        log_info "Removing symlink ${description}: ${file}"
        if rm -f "${file}"; then
            log_success "Removed symlink: ${file}"
        else
            log_error "Failed to remove symlink: ${file}"
            return 1
        fi
    else
        log_info "${description} not found: ${file}"
    fi
    return 0
}

# Remove configuration profile
remove_config_profile() {
    local profile_id=$1
    
    log_info "Checking for configuration profile: ${profile_id}"
    
    if profiles show | grep -q "${profile_id}"; then
        log_info "Found configuration profile: ${profile_id}"
        log_info "Removing configuration profile..."
        
        if profiles remove -identifier "${profile_id}" 2>/dev/null; then
            log_success "Successfully removed configuration profile: ${profile_id}"
        else
            log_warning "Could not remove configuration profile (may require manual removal): ${profile_id}"
        fi
    else
        log_info "Configuration profile not found: ${profile_id}"
    fi
}

# Kill any running processes
kill_processes() {
    local process_name=$1
    local description=$2
    
    log_info "Checking for running ${description} processes..."
    
    local pids=$(pgrep -f "${process_name}" 2>/dev/null)
    
    if [[ -n "${pids}" ]]; then
        log_info "Found running ${description} processes: ${pids}"
        log_info "Terminating processes..."
        
        if killall -9 "${process_name}" 2>/dev/null; then
            log_success "Successfully terminated ${description} processes"
        else
            log_warning "Could not terminate all ${description} processes"
        fi
        
        sleep 1
    else
        log_info "No running ${description} processes found"
    fi
}

################################################################################
# Main Uninstallation Functions
################################################################################

# Uninstall App Auto Patch
uninstall_app_auto_patch() {
    echo ""
    echo "=============================================================================="
    echo "  Uninstalling App Auto Patch"
    echo "=============================================================================="
    echo ""
    
    # Stop any running App Auto Patch processes
    kill_processes "App-Auto-Patch" "App Auto Patch"
    kill_processes "appautopatch" "App Auto Patch"
    
    # Stop and remove LaunchDaemons
    stop_launchdaemon "${AAP_LAUNCHDAEMON}"
    stop_launchdaemon "${AAP_LAUNCHDAEMON_ALT}"
    
    # Remove main directory and all contents
    remove_directory "${AAP_MAIN_DIR}" "App Auto Patch main directory"
    
    # Remove symlink
    remove_file "${AAP_SYMLINK}" "App Auto Patch symlink"
    
    # Remove preferences
    remove_file "${AAP_LOCAL_PLIST}" "App Auto Patch preferences"
    
    # Remove configuration profile
    remove_config_profile "${AAP_PROFILE_ID}"
    
    # Search for and remove any additional AAP-related files
    log_info "Searching for additional App Auto Patch files..."
    
    # Check for any other LaunchDaemons that might be related
    for plist in /Library/LaunchDaemons/*autopatch*.plist; do
        if [[ -f "${plist}" ]]; then
            stop_launchdaemon "${plist}"
        fi
    done
    
    # Check for any preferences in user directories (if needed)
    if [[ -d "/Users" ]]; then
        for user_home in /Users/*; do
            if [[ -d "${user_home}/Library/Preferences" ]]; then
                user_prefs="${user_home}/Library/Preferences/com.secondsonconsulting.appautopatch.plist"
                if [[ -f "${user_prefs}" ]]; then
                    remove_file "${user_prefs}" "User-level App Auto Patch preferences"
                fi
            fi
        done
    fi
    
    log_success "App Auto Patch uninstallation complete"
}

# Uninstall Installomator
uninstall_installomator() {
    echo ""
    echo "=============================================================================="
    echo "  Uninstalling Installomator"
    echo "=============================================================================="
    echo ""
    
    # Stop any running Installomator processes
    kill_processes "Installomator" "Installomator"
    
    # Remove main Installomator directory
    remove_directory "${INSTALLOMATOR_DIR}" "Installomator directory"
    
    # Remove Installomator symlink
    remove_file "${INSTALLOMATOR_SYMLINK}" "Installomator symlink"
    
    # Remove Installomator script if it exists standalone
    if [[ -f "${INSTALLOMATOR_SCRIPT}" ]] && [[ ! -d "${INSTALLOMATOR_DIR}" ]]; then
        remove_file "${INSTALLOMATOR_SCRIPT}" "Installomator script"
    fi
    
    # Search for any other Installomator-related files
    log_info "Searching for additional Installomator files..."
    
    # Check common locations
    local installomator_locations=(
        "/Library/Management/Installomator"
        "/opt/Installomator"
    )
    
    for location in "${installomator_locations[@]}"; do
        if [[ -d "${location}" ]]; then
            remove_directory "${location}" "Additional Installomator directory"
        fi
    done
    
    log_success "Installomator uninstallation complete"
}

# Verify swiftDialog is preserved
verify_swiftdialog_preserved() {
    echo ""
    echo "=============================================================================="
    echo "  Verifying swiftDialog Preservation"
    echo "=============================================================================="
    echo ""
    
    local dialog_locations=(
        "/usr/local/bin/dialog"
        "/Library/Application Support/Dialog"
        "/Applications/Dialog.app"
    )
    
    local dialog_found=false
    
    for location in "${dialog_locations[@]}"; do
        if [[ -e "${location}" ]]; then
            log_skip "swiftDialog preserved: ${location}"
            dialog_found=true
        fi
    done
    
    if [[ "${dialog_found}" == true ]]; then
        log_success "swiftDialog has been preserved as requested"
    else
        log_info "swiftDialog was not detected on this system"
    fi
}

# Generate summary report
generate_summary() {
    echo ""
    echo "=============================================================================="
    echo "  Uninstallation Summary"
    echo "=============================================================================="
    echo ""
    
    log_info "Uninstallation completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "Full log saved to: ${LOG_FILE}"
    
    echo ""
    echo -e "${GREEN}Removed:${NC}"
    echo "  ✓ App Auto Patch"
    echo "  ✓ Installomator"
    echo ""
    echo -e "${CYAN}Preserved:${NC}"
    echo "  ✓ swiftDialog"
    echo ""
    
    # Check if any directories still exist
    local cleanup_needed=false
    
    if [[ -d "${AAP_MAIN_DIR}" ]]; then
        log_warning "App Auto Patch directory still exists: ${AAP_MAIN_DIR}"
        cleanup_needed=true
    fi
    
    if [[ -d "${INSTALLOMATOR_DIR}" ]]; then
        log_warning "Installomator directory still exists: ${INSTALLOMATOR_DIR}"
        cleanup_needed=true
    fi
    
    if [[ "${cleanup_needed}" == true ]]; then
        echo ""
        log_warning "Some items could not be removed automatically. Please check the log file for details."
    else
        echo ""
        log_success "All components successfully removed!"
    fi
    
    echo ""
    echo "=============================================================================="
}

################################################################################
# Main Execution
################################################################################

main() {
    # Print header
    print_header
    
    # Check if running as root
    check_root
    
    # Initialize log file
    log_info "==================== UNINSTALLATION STARTED ===================="
    log_info "Script: ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    log_info "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "User: $(whoami)"
    log_info "macOS Version: $(sw_vers -productVersion)"
    log_info "==============================================================="
    
    # Confirm with user
    confirm_uninstall
    
    # Uninstall App Auto Patch
    uninstall_app_auto_patch
    
    # Uninstall Installomator
    uninstall_installomator
    
    # Verify swiftDialog is preserved
    verify_swiftdialog_preserved
    
    # Generate summary
    generate_summary
    
    log_info "==================== UNINSTALLATION COMPLETED ===================="
}

# Run main function
main

exit 0
