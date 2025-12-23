# Whispering Nix Flake

Nix flake for [Whispering](https://github.com/EpicenterHQ/epicenter/tree/main/apps/whispering) - an open-source speech-to-text application built with Tauri and SvelteKit.

## Features

- 📦 Packages Whispering for NixOS/Nix
- 🔧 NixOS module for system-wide configuration
- 🏠 Home Manager module for per-user configuration
- 🛠️ Development shell for contributing
- 🔌 Overlay for easy integration

## Quick Start

### Try it out

```bash
# Run directly without installing
nix run github:your-username/whispering-nix

# Or build first
nix build github:your-username/whispering-nix
./result/bin/whispering
```

### Install in a Flake-based NixOS Configuration

Add the flake to your inputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    whispering.url = "github:clairesrc/whispering-nix";
    # Or from local path:
    # whispering.url = "path:/path/to/whispering-nix";
  };

  outputs = { self, nixpkgs, whispering, ... }: {
    nixosConfigurations.your-hostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        whispering.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Then enable in your configuration:

```nix
# configuration.nix
{ config, pkgs, ... }:

{
  programs.whispering = {
    enable = true;
    autostart = false;           # Set to true to start on login
    enableGlobalShortcuts = true; # Enable global keyboard shortcuts
    enablePipewire = true;       # Enable PipeWire for audio
  };

  # Ensure your user is in the required groups
  users.users.your-username.extraGroups = [ "audio" "input" ];
}
```

### Home Manager Module

For per-user installation with Home Manager:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    whispering.url = "github:your-username/whispering-nix";
  };

  outputs = { self, nixpkgs, home-manager, whispering, ... }: {
    homeConfigurations.your-username = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        whispering.homeManagerModules.default
        {
          programs.whispering = {
            enable = true;
            autostart = true;
          };
        }
      ];
    };
  };
}
```

### Using the Overlay

Add Whispering to your pkgs:

```nix
{
  nixpkgs.overlays = [ whispering.overlays.default ];
}
```

Then use `pkgs.whispering` anywhere in your configuration.

## Development

Enter the development shell to contribute to Whispering:

```bash
nix develop

# Then:
git clone https://github.com/EpicenterHQ/epicenter.git
cd epicenter
bun install
cd apps/whispering
bun tauri dev
```

## Module Options

### NixOS Module (`programs.whispering`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable Whispering |
| `package` | package | `whispering` | The package to use |
| `autostart` | bool | `false` | Autostart on login |
| `enableGlobalShortcuts` | bool | `true` | Enable global keyboard shortcuts |
| `enablePipewire` | bool | `true` | Enable PipeWire audio support |

### Home Manager Module (`programs.whispering`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable Whispering |
| `package` | package | `whispering` | The package to use |
| `autostart` | bool | `false` | Autostart on login |
| `settings` | attrs | `{}` | Configuration (reserved for future use) |

## Requirements

- NixOS or Nix with flakes enabled
- PipeWire or PulseAudio for audio
- Desktop environment with D-Bus support
- For global shortcuts: user must be in `input` group

## Troubleshooting

### Audio not working

Ensure PipeWire is properly configured:

```nix
services.pipewire = {
  enable = true;
  alsa.enable = true;
  pulse.enable = true;
};
```

### Global shortcuts not working

1. Ensure your user is in the `input` group:
   ```nix
   users.users.your-username.extraGroups = [ "input" ];
   ```

2. On Wayland, you may need compositor-specific configuration

3. Log out and back in after group changes

### WebKitGTK issues

Enable GPU acceleration:

```nix
hardware.opengl.enable = true;
```

### Getting the SHA256 hash

After first build attempt, get the correct hash:

```bash
nix-prefetch-github EpicenterHQ epicenter --rev main
# Or for a specific version:
nix-prefetch-github EpicenterHQ epicenter --rev v7.11.0
```

Update the `srcHash` in `flake.nix` with the output.

## What is Whispering?

Whispering is an open-source speech-to-text application that supports:

- **Local transcription**: Whisper C++, Moonshine, Parakeet (completely private)
- **Cloud transcription**: Groq, OpenAI, ElevenLabs (fast and accurate)
- **AI transformations**: Fix grammar, translate, reformat with any LLM
- **Global shortcuts**: Press a key combo, speak, get text anywhere
- **Voice Activity Detection**: Hands-free recording

Built with Svelte 5 + Tauri for a tiny (~22MB), fast, cross-platform experience.

## License

This flake is provided under MIT license.
Whispering itself is licensed under [AGPLv3](https://github.com/EpicenterHQ/epicenter/blob/main/LICENSE).

## Links

- [Whispering App](https://whispering.epicenterhq.com)
- [Source Repository](https://github.com/EpicenterHQ/epicenter/tree/main/apps/whispering)
- [GitHub Releases](https://github.com/EpicenterHQ/epicenter/releases)
- [Tauri Framework](https://tauri.app)
