# NetworkAnalyzer Setup Guide

This guide will help you configure the Xcode project to build and run the content filter.

## Project Structure

```
NetworkAnalyzer/
├── NetworkAnalyzer/              # Main app target
│   ├── NetworkAnalyzerApp.swift
│   ├── ContentView.swift
│   ├── Info.plist
│   ├── NetworkAnalyzer.entitlements
│   ├── Managers/
│   │   ├── SystemExtensionManager.swift
│   │   ├── FilterManager.swift
│   │   └── NetworkLogger.swift
│   └── Views/
│       ├── FilterStatusView.swift
│       ├── ConnectionLogView.swift
│       └── SettingsView.swift
└── NetworkAnalyzerExtension/     # System Extension target
    ├── main.swift
    ├── FilterDataProvider.swift
    ├── Info.plist
    └── NetworkAnalyzerExtension.entitlements
```

## Step 1: Add Network Extension Target in Xcode

1. Open `NetworkAnalyzer.xcodeproj` in Xcode
2. Go to **File > New > Target...**
3. Select **macOS > Network Extension**
4. Configure:
   - Product Name: `NetworkAnalyzerExtension`
   - Bundle Identifier: (Xcode will auto-generate: `com.safeme.networkanalyzer.networkanalyzerextension`)
   - **Provider Type: Filter Data Provider** (important!)
   - Team: Same as main app
   - Language: Swift
5. When asked to activate scheme, click **Activate**
6. When asked to enable the Network Extension capability, click **Enable**

> **Note**: If you don't see "Network Extension" template, you may need to scroll down in the template list. It's under the "Application Extension" section.

## Step 2: Configure Extension Target Files

After creating the target, Xcode creates default files. Replace them:

1. **Delete** the auto-generated Swift files in the extension target
2. In Xcode's Project Navigator, drag these files from Finder into the `NetworkAnalyzerExtension` group:
   - `main.swift`
   - `FilterDataProvider.swift`
3. Make sure **Target Membership** is set to `NetworkAnalyzerExtension` only

## Step 3: Configure Extension Build Settings

Select the `NetworkAnalyzerExtension` target and configure:

### General Tab
- Deployment Target: macOS 15.0
- Bundle Identifier: `com.safeme.NetworkAnalyzer.Extension`

### Build Settings Tab
- Search for `Info.plist File` and set it to: `NetworkAnalyzerExtension/Info.plist`
- Search for `Code Signing Entitlements` and set it to: `NetworkAnalyzerExtension/NetworkAnalyzerExtension.entitlements`
- Ensure `Skip Install` is set to `Yes`

### Signing & Capabilities Tab
1. Enable **Automatically manage signing**
2. Add Capability: **App Groups**
   - Add group: `group.com.safeme.NetworkAnalyzer`
3. Add Capability: **Network Extensions**
   - Check: `Content Filter Provider`

## Step 4: Configure Main App Target

Select the `NetworkAnalyzer` target:

### Build Settings Tab
- Set `Info.plist File` to: `NetworkAnalyzer/Info.plist`
- Set `Code Signing Entitlements` to: `NetworkAnalyzer/NetworkAnalyzer.entitlements`

### Signing & Capabilities Tab
1. Add Capability: **App Groups**
   - Add group: `group.com.safeme.NetworkAnalyzer`
2. Add Capability: **Network Extensions**
   - Check: `Content Filter Provider`
3. Add Capability: **System Extension**

### Build Phases Tab
1. Add **Copy Files** phase
2. Configure:
   - Destination: `System Extensions`
   - Subpath: (leave empty)
   - Add `NetworkAnalyzerExtension.systemextension`

## Step 5: Embed Extension in Main App

1. Select the `NetworkAnalyzer` target
2. Go to **General > Frameworks, Libraries, and Embedded Content**
3. Click **+** and add `NetworkAnalyzerExtension.systemextension`
4. Set **Embed** to: `Embed Without Signing`

Or use Build Phases:
1. Add a **Copy Files** build phase
2. Set Destination to **System Extensions**
3. Add `NetworkAnalyzerExtension.systemextension`

## Step 6: Add Required Frameworks

For both targets, ensure these frameworks are linked:

**Main App:**
- NetworkExtension.framework
- SystemExtensions.framework

**Extension:**
- NetworkExtension.framework

## Step 7: Apple Developer Portal Setup

You need entitlements from Apple for Network Extensions:

1. Go to [developer.apple.com](https://developer.apple.com)
2. Go to **Certificates, Identifiers & Profiles**
3. Create/Edit your App ID for both:
   - `com.safeme.NetworkAnalyzer`
   - `com.safeme.networkanalyzer.networkanalyzerextension`
4. Enable capabilities:
   - **App Groups**: `group.com.safeme.NetworkAnalyzer`
   - **Network Extensions**: Content Filter Provider
   - **System Extension** (main app only)

## Step 8: Testing

### Development Testing
1. Build the app
2. **Important**: Copy the built app to `/Applications/` folder
   - System Extensions only work from `/Applications`
3. Run from `/Applications/NetworkAnalyzer.app`

### Post-Action Script (Optional)
Add to your scheme's Build Post-action:
```bash
ditto "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app" "/Applications/${PRODUCT_NAME}.app"
```

### First Run
1. Launch the app from `/Applications`
2. Click **Install** to activate the system extension
3. macOS will prompt for approval in **System Settings > Privacy & Security**
4. After approval, click **Enable** to start the content filter
5. macOS may prompt again in **System Settings > Network > Filters**

## Troubleshooting

### Extension Not Found
- Ensure the extension is embedded in the app bundle
- Check the extension is in `Contents/Library/SystemExtensions/`
- Verify bundle identifiers match

### Permission Denied
- App must be in `/Applications`
- Must be signed with valid Developer ID (for distribution)
- During development, use the `get-task-allow` entitlement

### Filter Not Starting
- Check Console.app for logs from `com.safeme.NetworkAnalyzer.Extension`
- Verify the extension's Info.plist has correct `NSExtensionPrincipalClass`

### Common Errors
- `OSSystemExtensionErrorUnsupportedParentBundleLocation`: Move app to /Applications
- `OSSystemExtensionErrorExtensionNotFound`: Extension not properly embedded
- `NEFilterConfigurationPermissionDenied`: Enable in System Settings > Network

## Resources

- [Apple: Filtering Network Traffic](https://developer.apple.com/documentation/networkextension/filtering-network-traffic)
- [Apple: Content Filter Providers](https://developer.apple.com/documentation/networkextension/content-filter-providers)
- [Apple: System Extensions](https://developer.apple.com/documentation/systemextensions)
- [Network Extension Debugging](https://www.avanderlee.com/debugging/network-extension-debugging-macos/)
