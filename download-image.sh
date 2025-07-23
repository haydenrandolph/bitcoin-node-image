#!/bin/bash

# Bitcoin Node Image Download Script
# Downloads the latest Bitcoin node image for flashing with Raspberry Pi Imager

set -e

# Configuration
BUCKET="bitcoin-node-artifact-store"
DOWNLOAD_DIR="$HOME/Downloads/bitcoin-node"
FILENAME="raspberry-pi-bitcoin-node_latest.img.xz"
EXTRACTED_NAME="raspberry-pi-bitcoin-node_latest.img"

# Service account authentication
SERVICE_ACCOUNT_KEY_FILE="$(dirname "$0")/gcp-service-account-key.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required tools are installed
check_dependencies() {
    print_status "Checking dependencies..."
    
    local missing_tools=()
    
    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi
    
    if ! command -v xz &> /dev/null; then
        missing_tools+=("xz")
    fi
    
    if ! command -v wc &> /dev/null; then
        missing_tools+=("coreutils")
    fi
    
    if ! command -v gcloud &> /dev/null; then
        missing_tools+=("gcloud")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo "Please install them and try again:"
        echo "  Ubuntu/Debian: sudo apt install curl xz-utils"
        echo "  macOS: brew install curl xz"
        echo "  Windows: Install via package manager or download manually"
        echo "  Google Cloud CLI: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    
    print_success "All dependencies found"
}

# Setup GCP authentication
setup_gcp_auth() {
    print_status "Setting up GCP authentication..."
    
    # Check if service account key file exists
    if [ ! -f "$SERVICE_ACCOUNT_KEY_FILE" ]; then
        print_error "Service account key file not found: $SERVICE_ACCOUNT_KEY_FILE"
        echo ""
        echo "Please save your GCP service account JSON key as:"
        echo "  $SERVICE_ACCOUNT_KEY_FILE"
        echo ""
        echo "This should be the same key used in your GitHub Actions GCP_SA_KEY secret."
        exit 1
    fi
    
    # Authenticate with service account
    if gcloud auth activate-service-account --key-file="$SERVICE_ACCOUNT_KEY_FILE"; then
        print_success "GCP authentication successful"
    else
        print_error "GCP authentication failed"
        exit 1
    fi
}

# Create download directory
create_download_dir() {
    print_status "Creating download directory: $DOWNLOAD_DIR"
    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR"
}

# Download the image
download_image() {
    print_status "Downloading latest Bitcoin node image..."
    print_status "Source: gs://$BUCKET/raspberry-pi-bitcoin-node_latest.img.xz"
    print_status "This may take several minutes depending on your internet connection..."
    
    # Check if file already exists and ask user
    if [ -f "$FILENAME" ]; then
        print_warning "File $FILENAME already exists in $DOWNLOAD_DIR"
        read -p "Do you want to re-download? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Using existing file: $FILENAME"
            return
        fi
    fi
    
    # Download using gsutil with authentication
    if gsutil cp "gs://$BUCKET/raspberry-pi-bitcoin-node_latest.img.xz" "$FILENAME"; then
        print_success "Download completed!"
    else
        print_error "Download failed!"
        print_error "Check your GCP authentication and permissions"
        exit 1
    fi
}

# Verify download
verify_download() {
    print_status "Verifying download..."
    
    if [ ! -f "$FILENAME" ]; then
        print_error "Downloaded file not found: $FILENAME"
        exit 1
    fi
    
    local file_size=$(wc -c < "$FILENAME")
    local file_size_mb=$((file_size / 1024 / 1024))
    
    print_status "File size: ${file_size_mb} MB"
    
    if [ $file_size_mb -lt 100 ]; then
        print_error "File seems too small (${file_size_mb} MB). Download may have failed."
        exit 1
    fi
    
    print_success "Download verification passed"
}

# Extract the image
extract_image() {
    print_status "Extracting image (this may take a few minutes)..."
    
    # Check if extracted file already exists
    if [ -f "$EXTRACTED_NAME" ]; then
        print_warning "Extracted file $EXTRACTED_NAME already exists"
        read -p "Do you want to re-extract? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Using existing extracted file: $EXTRACTED_NAME"
            return
        fi
        # Remove existing file if user wants to re-extract
        rm "$EXTRACTED_NAME"
    fi
    
    if xz -d "$FILENAME"; then
        print_success "Extraction completed!"
    else
        print_error "Extraction failed!"
        exit 1
    fi
}

# Verify extracted image
verify_extracted() {
    print_status "Verifying extracted image..."
    
    if [ ! -f "$EXTRACTED_NAME" ]; then
        print_error "Extracted file not found: $EXTRACTED_NAME"
        exit 1
    fi
    
    local file_size=$(wc -c < "$EXTRACTED_NAME")
    local file_size_gb=$((file_size / 1024 / 1024 / 1024))
    
    print_status "Extracted image size: ${file_size_gb} GB"
    
    if [ $file_size_gb -lt 4 ]; then
        print_error "Extracted image seems too small (${file_size_gb} GB). Extraction may have failed."
        exit 1
    fi
    
    print_success "Extracted image verification passed"
}

# Display next steps
show_next_steps() {
    local full_path="$DOWNLOAD_DIR/$EXTRACTED_NAME"
    
    echo
    print_success "🎉 Bitcoin node image ready for flashing!"
    echo
    echo "📁 Image location: $full_path"
    echo "📏 Image size: $(($(wc -c < "$EXTRACTED_NAME") / 1024 / 1024 / 1024)) GB"
    echo
    echo "🔄 Next steps:"
    echo "   1. Open Raspberry Pi Imager"
    echo "   2. Click 'Choose OS' → 'Use custom'"
    echo "   3. Select: $full_path"
    echo "   4. Choose your SD card"
    echo "   5. Click 'Write'"
    echo
    echo "💡 After flashing:"
echo "   - Insert SD card into Raspberry Pi"
echo "   - Boot the Pi"
echo "   - Access web dashboard at: http://pi.local:3000"
echo "   - SSH access: ssh pi@pi.local (password: raspberry)"
echo "   - SSH port forward: ssh -L 3000:localhost:3000 pi@pi.local"
    echo
    print_warning "⚠️  Make sure you have a 32GB+ SD card for this image!"
}

# Cleanup function
cleanup() {
    print_status "Cleaning up compressed file..."
    if [ -f "$FILENAME" ]; then
        rm "$FILENAME"
        print_success "Compressed file removed"
    fi
}

# Main execution
main() {
    echo "🚀 Bitcoin Node Image Downloader"
    echo "=================================="
    echo
    
    check_dependencies
    setup_gcp_auth
    create_download_dir
    download_image
    verify_download
    extract_image
    verify_extracted
    
    # Ask if user wants to clean up compressed file
    echo
    read -p "Remove compressed file to save space? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        cleanup
    fi
    
    show_next_steps
}

# Handle script interruption
trap 'print_error "Script interrupted. Cleaning up..."; cleanup; exit 1' INT TERM

# Run main function
main "$@" 