# Releasing Winby

This document describes how to set up and use the automated build and release system.

## Overview

Winby uses GitHub Actions to automatically build, sign, notarize, and release macOS app bundles. The workflow:

1. Builds the Swift package for ARM64
2. Creates a proper .app bundle with all dependencies
3. Signs the app with Developer ID certificates
4. Creates a DMG installer
5. Notarizes with Apple for Gatekeeper approval
6. Generates Sparkle appcast.xml for auto-updates
7. Creates a GitHub Release with the DMG

## Prerequisites

### 1. Apple Developer Account

You need an Apple Developer account ($99/year) with:
- Developer ID Application certificate
- Developer ID Installer certificate

### 2. App Icon

Create an app icon and save it as `Resources/Winby.icns`. You can use Icon Composer or an online tool to generate the .icns file from a 1024x1024 PNG.

### 3. Sparkle Keys

Generate EdDSA keys for Sparkle update signing:

```bash
# Build the project first to get Sparkle tools
swift build

# Generate keys
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

This outputs:
- A private key (save securely, add to GitHub secrets)
- A public key (add to GitHub secrets and Info.plist)

## GitHub Secrets

Configure these secrets in your GitHub repository settings (Settings → Secrets and variables → Actions):

### Code Signing Certificates

| Secret | Description | How to get it |
|--------|-------------|---------------|
| `DEVELOPER_ID_APPLICATION` | Base64-encoded .p12 certificate | Export from Keychain Access, then `base64 -i cert.p12` |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | Password used when exporting the .p12 | The password you set during export |
| `DEVELOPER_ID_INSTALLER` | Base64-encoded installer .p12 certificate | Same process as above |
| `DEVELOPER_ID_INSTALLER_PASSWORD` | Password for installer cert | The password you set during export |
| `DEVELOPER_ID_NAME` | Full signing identity name | e.g., `Developer ID Application: Jesse Vincent (ABC123XYZ)` |

### Apple Notarization

| Secret | Description | How to get it |
|--------|-------------|---------------|
| `APPLE_ID` | Your Apple ID email | The email for your Apple Developer account |
| `APPLE_ID_PASSWORD` | App-specific password | Generate at appleid.apple.com → Security → App-Specific Passwords |
| `APPLE_TEAM_ID` | Your Team ID | Found in Apple Developer portal under Membership |

### Sparkle Auto-Updates

| Secret | Description | How to get it |
|--------|-------------|---------------|
| `SPARKLE_PRIVATE_KEY` | EdDSA private key | Output from `generate_keys` command |
| `SPARKLE_PUBLIC_KEY` | EdDSA public key | Output from `generate_keys` command |

## Exporting Certificates

1. Open **Keychain Access**
2. Find your "Developer ID Application" certificate
3. Right-click → Export
4. Save as .p12 with a strong password
5. Convert to base64:
   ```bash
   base64 -i "Developer ID Application.p12" | pbcopy
   ```
6. Paste into GitHub secret

Repeat for the "Developer ID Installer" certificate.

## Creating a Release

### Automatic (Recommended)

Push a version tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow automatically:
- Builds and signs the app
- Creates Winby-1.0.0.dmg
- Notarizes with Apple
- Generates appcast.xml
- Creates a GitHub Release

### Manual

1. Go to Actions → "Build and Release macOS App"
2. Click "Run workflow"
3. Enter the version number (e.g., `1.0.0`)
4. Click "Run workflow"

## Sparkle Auto-Updates

The app checks for updates via the appcast.xml file hosted on GitHub Releases. Users will be prompted to update when a new version is available.

The appcast URL is: `https://github.com/obra/winby/releases/latest/download/appcast.xml`

## Troubleshooting

### "Developer ID Application" not found

Make sure you have a valid Developer ID certificate installed. You can create one in the Apple Developer portal under Certificates, Identifiers & Profiles.

### Notarization fails

- Ensure your Apple ID password is an app-specific password, not your regular password
- Check that your Team ID is correct
- Verify the app doesn't contain any unsigned code

### Code signing fails

- Verify the certificate hasn't expired
- Make sure the base64 encoding doesn't have line breaks
- Check that the password matches what you used during export

### Sparkle signature invalid

- Ensure the private key in secrets matches the public key in Info.plist
- Regenerate keys if needed and update both secrets

## Files Reference

| File | Purpose |
|------|---------|
| `.github/workflows/build-and-release.yml` | CI/CD workflow |
| `Winby.entitlements` | Code signing entitlements |
| `Resources/Winby.icns` | App icon (you must create this) |
| `Package.swift` | Swift package manifest with Sparkle dependency |
