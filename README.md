# NoXcode

A macOS app and CLI tool for building and launching Xcode projects on multiple simulators in parallel.

## Features

- List available iOS, tvOS, watchOS, and visionOS simulators
- Select multiple simulators (e.g., iPhone + iPad + Apple TV)
- Choose an Xcode project, scheme, and build configuration
- Save selections to a `.noxcode.json` config file at the project root
- Build for all required platforms in parallel
- Install and launch on all selected simulators

## CLI Usage

```bash
# List available simulators
noxcode list-sims

# Initialize a config file (interactive or with flags)
noxcode init --project MyApp.xcodeproj --scheme MyApp --config Debug

# Run build + install + launch using .noxcode.json
noxcode run

# Dry-run (show what would happen without executing)
noxcode run --dry-run
```

## Config File

The `.noxcode.json` file is stored at the project root:

```json
{
  "project": "MyApp.xcodeproj",
  "scheme": "MyApp",
  "configuration": "Debug",
  "launchArguments": ["--uitesting"],
  "environmentVariables": {
    "API_BASE_URL": "https://staging.example.com"
  },
  "simulators": [
    { "udid": "ABC123...", "platform": "iOS" },
    { "udid": "DEF456...", "platform": "tvOS" }
  ],
  "derivedDataPath": ".noxcode/DerivedData"
}
```

`launchArguments` are appended to `xcrun simctl launch ...` and environment variables are passed with the `SIMCTL_CHILD_` prefix so they appear in the launched app environment.

## Architecture

```
Sources/
├── CoreModels/       # Shared data models (Platform, SimDevice, Config, etc.)
├── ProcessRunner/    # Async subprocess execution with streaming output
├── Simctl/           # xcrun simctl wrapper (list, boot, install, launch)
├── XcodeBuild/       # xcodebuild wrapper (list schemes, build, showBuildSettings)
├── ProjectConfig/    # .noxcode.json read/write
├── NoXcodeKit/       # High-level orchestration API
└── noxcode/          # CLI using ArgumentParser
```

## License

MIT