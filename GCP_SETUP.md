# GCP Storage Setup for Bitcoin Node Image Builds

This document explains how to set up Google Cloud Platform storage for hosting the built Bitcoin node images, bypassing GitHub's artifact size limits.

## Prerequisites

1. A Google Cloud Platform account
2. A GCP project with billing enabled
3. The `gsutil` command-line tool (or Google Cloud Console access)

## Setup Steps

### 1. Create a GCP Storage Bucket

```bash
# Create the bucket (if not already created)
gsutil mb gs://bitcoin-node-artifact-store

# Make the bucket publicly readable (optional, for direct downloads)
gsutil iam ch allUsers:objectViewer gs://bitcoin-node-artifact-store
```

### 2. Create a Service Account

1. Go to the [Google Cloud Console](https://console.cloud.google.com/)
2. Navigate to **IAM & Admin** > **Service Accounts**
3. Click **Create Service Account**
4. Name it something like `github-actions-bitcoin-node`
5. Add a description: "Service account for GitHub Actions to upload Bitcoin node images"

### 3. Grant Storage Permissions

1. After creating the service account, click on it
2. Go to the **Permissions** tab
3. Click **Grant Access**
4. Add the following roles:
   - **Storage Object Admin** (`roles/storage.objectAdmin`)
   - **Storage Object Viewer** (`roles/storage.objectViewer`)

### 4. Create and Download Service Account Key

1. In the service account details, go to the **Keys** tab
2. Click **Add Key** > **Create new key**
3. Choose **JSON** format
4. Download the JSON file

### 5. Add Secret to GitHub Repository

1. Go to your GitHub repository
2. Navigate to **Settings** > **Secrets and variables** > **Actions**
3. Click **New repository secret**
4. Name: `GCP_SA_KEY`
5. Value: Copy the entire contents of the downloaded JSON file

## Usage

Once set up, the GitHub Actions workflow will:

1. Build the Bitcoin node image
2. Compress it with xz
3. Upload it to `gs://bitcoin-node-artifact-store/` with a timestamp
4. Create a `latest` symlink for easy access
5. Display download URLs in the workflow output

## Download URLs

After a successful build, you can download the image using:

```bash
# Download the latest version
curl -L 'https://storage.googleapis.com/bitcoin-node-artifact-store/raspberry-pi-bitcoin-node_latest.img.xz' -o raspberry-pi-bitcoin-node.img.xz

# Extract the image
xz -d raspberry-pi-bitcoin-node.img.xz

# Write to SD card (replace /dev/sdX with your SD card device)
sudo dd if=raspberry-pi-bitcoin-node.img of=/dev/sdX bs=4M status=progress
```

## Security Notes

- The service account key has minimal permissions (only storage access)
- Consider using Workload Identity Federation for production use
- The bucket can be made private if you prefer to use signed URLs for downloads

## Troubleshooting

### Permission Denied Errors
- Ensure the service account has the correct IAM roles
- Verify the JSON key is properly formatted in the GitHub secret

### Bucket Not Found
- Check that the bucket name matches exactly: `bitcoin-node-artifact-store`
- Ensure the bucket exists in the same project as the service account

### Upload Failures
- Check that the service account has billing access to the project
- Verify the bucket is in the same region as your workflow (us-central1 recommended) 