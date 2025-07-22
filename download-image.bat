@echo off
setlocal enabledelayedexpansion

REM Bitcoin Node Image Download Script for Windows
REM Downloads the latest Bitcoin node image for flashing with Raspberry Pi Imager

echo 🚀 Bitcoin Node Image Downloader
echo ==================================
echo.

REM Configuration
set BUCKET=bitcoin-node-artifact-store
set LATEST_URL=https://storage.googleapis.com/%BUCKET%/raspberry-pi-bitcoin-node_latest.img.xz
set DOWNLOAD_DIR=%USERPROFILE%\Downloads\bitcoin-node
set FILENAME=raspberry-pi-bitcoin-node_latest.img.xz
set EXTRACTED_NAME=raspberry-pi-bitcoin-node_latest.img

REM Check if curl is available
curl --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] curl is not installed or not in PATH
    echo Please install curl from: https://curl.se/windows/
    echo Or use WSL/Linux subsystem
    pause
    exit /b 1
)

REM Create download directory
echo [INFO] Creating download directory: %DOWNLOAD_DIR%
if not exist "%DOWNLOAD_DIR%" mkdir "%DOWNLOAD_DIR%"
cd /d "%DOWNLOAD_DIR%"

REM Check if file already exists
if exist "%FILENAME%" (
    echo [WARNING] File %FILENAME% already exists in %DOWNLOAD_DIR%
    set /p REDOWNLOAD="Do you want to re-download? (y/N): "
    if /i not "!REDOWNLOAD!"=="y" (
        echo [INFO] Using existing file: %FILENAME%
        goto :extract
    )
)

REM Download the image
echo [INFO] Downloading latest Bitcoin node image...
echo [INFO] URL: %LATEST_URL%
echo [INFO] This may take several minutes depending on your internet connection...
echo.

curl -L -o "%FILENAME%" "%LATEST_URL%"
if errorlevel 1 (
    echo [ERROR] Download failed!
    pause
    exit /b 1
)

REM Check if we got an error page instead of the file
findstr /i "Access Denied Forbidden Error" "%FILENAME%" >nul 2>&1
if not errorlevel 1 (
    echo [ERROR] Download failed - Access denied to bucket
    echo [ERROR] The bucket may not be publicly readable
    del "%FILENAME%" 2>nul
    pause
    exit /b 1
)

echo [SUCCESS] Download completed!

:extract
REM Check if extracted file already exists
if exist "%EXTRACTED_NAME%" (
    echo [WARNING] Extracted file %EXTRACTED_NAME% already exists
    set /p REEXTRACT="Do you want to re-extract? (y/N): "
    if /i not "!REEXTRACT!"=="y" (
        echo [INFO] Using existing extracted file: %EXTRACTED_NAME%
        goto :next_steps
    )
)

REM Extract the image
echo [INFO] Extracting image (this may take a few minutes)...
echo.

REM Check if 7-Zip is available (common on Windows)
7z x "%FILENAME%" >nul 2>&1
if errorlevel 1 (
    echo [WARNING] 7-Zip not found, trying with built-in tools...
    echo [ERROR] Automatic extraction not available on Windows
    echo Please manually extract %FILENAME% using 7-Zip or similar tool
    echo Download 7-Zip from: https://7-zip.org/
    pause
    exit /b 1
)

echo [SUCCESS] Extraction completed!

:next_steps
REM Display next steps
echo.
echo [SUCCESS] 🎉 Bitcoin node image ready for flashing!
echo.
echo 📁 Image location: %DOWNLOAD_DIR%\%EXTRACTED_NAME%
echo.
echo 🔄 Next steps:
echo    1. Open Raspberry Pi Imager
echo    2. Click 'Choose OS' → 'Use custom'
echo    3. Select: %DOWNLOAD_DIR%\%EXTRACTED_NAME%
echo    4. Choose your SD card
echo    5. Click 'Write'
echo.
echo 💡 After flashing:
echo    - Insert SD card into Raspberry Pi
echo    - Boot the Pi
echo    - Access web dashboard at: http://pi.local:3000
echo    - Default SSH: pi/raspberry
echo.
echo [WARNING] ⚠️  Make sure you have a 32GB+ SD card for this image!
echo.

REM Ask if user wants to clean up compressed file
set /p CLEANUP="Remove compressed file to save space? (Y/n): "
if /i not "!CLEANUP!"=="n" (
    echo [INFO] Cleaning up compressed file...
    del "%FILENAME%"
    echo [SUCCESS] Compressed file removed
)

echo.
echo [INFO] Script completed successfully!
pause 