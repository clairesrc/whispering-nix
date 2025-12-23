{
  description = "Nix flake for Whispering - Open-source speech-to-text application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        # Rust toolchain - use stable with required components
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
          ];
        };

        # Common native build inputs for Tauri
        nativeBuildInputs = with pkgs; [
          pkg-config
          cmake
          rustToolchain
          cargo
          bun
          nodejs_20
          wrapGAppsHook3
          gobject-introspection
          makeWrapper
          shaderc # for glslc
          jq
        ];

        # Build inputs / libraries needed for Tauri + transcribe-rs
        buildInputs = with pkgs; [
          # Vulkan dependencies (for whisper-rs/ggml)
          vulkan-headers
          vulkan-loader

          # GTK and WebKit for Tauri
          gtk3
          webkitgtk_4_1
          libsoup_3
          glib
          glib-networking
          gsettings-desktop-schemas

          # Audio (CPAL, PipeWire, ALSA)
          alsa-lib
          pipewire
          pulseaudio
          jack2

          # System libraries
          openssl
          dbus
          at-spi2-atk
          atkmm

          # Graphics
          cairo
          pango
          gdk-pixbuf
          libglvnd # For OpenGL
          mesa # For software rendering fallbacks

          # X11 support
          xorg.libX11
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXi
          xorg.libxcb

          # Transcription dependencies (for transcribe-rs with whisper/moonshine/parakeet)
          onnxruntime

          # Accessibility
          at-spi2-core

          # System tray and misc
          libappindicator-gtk3
          librsvg

          # GStreamer for media handling
          gst_all_1.gstreamer
          gst_all_1.gst-plugins-base
          gst_all_1.gst-plugins-good
          gst_all_1.gst-plugins-bad
          gst_all_1.gst-plugins-ugly
          gst_all_1.gst-libav

          # Command line tools used by the app
          ffmpeg

          # C++ Standard Library (required for many Rust/C++ apps)
          stdenv.cc.cc.lib
        ];

        # Library path for runtime
        libPath = pkgs.lib.makeLibraryPath buildInputs;

        # Version from the upstream repo
        version = "7.11.0";

        # NOTE: To get the actual SHA256 hash, run:
        #   nix-prefetch-github EpicenterHQ epicenter --rev main
        # Or for a specific tag:
        #   nix-prefetch-github EpicenterHQ epicenter --rev v7.11.0
        # Then replace the hash below.
        srcHash = "sha256-Rtfcfs0KCM0LXDHOkIsJ7nUQrik04t0tOdRVnAFrurE=";

        src = pkgs.fetchFromGitHub {
          owner = "EpicenterHQ";
          repo = "epicenter";
          rev = "main"; # For reproducibility, pin to "v${version}" or specific commit
          hash = srcHash;
        };

        # Fixed-output derivation to fetch npm/bun dependencies
        # This has network access because it produces a content-addressed output
        # To get the hash: build once with lib.fakeHash, then use the correct hash from the error
        npmDepsHash = "sha256-EwinU+WpXpe8QW+4pdD2VDpFOm+aIpiV6kIg2Fru1xQ=";

        npmDeps = pkgs.stdenv.mkDerivation {
          pname = "whispering-npm-deps";
          inherit version src;

          nativeBuildInputs = with pkgs; [
            bun
            nodejs_20
            cacert
          ];

          # This is a fixed-output derivation - it has network access
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = npmDepsHash;

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            export BUN_INSTALL=$TMPDIR/bun

            # Install dependencies
            bun install --frozen-lockfile || bun install

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out
            cp -r node_modules $out/

            # Also copy any workspace node_modules
            find . -name 'node_modules' -type d | while read dir; do
              relpath=$(dirname "$dir")
              mkdir -p "$out/$relpath"
              cp -r "$dir" "$out/$relpath/"
            done

            runHook postInstall
          '';

          dontFixup = true;
        };

        # Fixed-output derivation for Cargo dependencies
        cargoDepsHash = "sha256-CZU/8pCKe+uKH7lyCQGnT2gY9F5grimSER+UxUEv4fo=";

        cargoDeps = pkgs.stdenv.mkDerivation {
          pname = "whispering-cargo-deps";
          inherit version src;
          nativeBuildInputs = with pkgs; [
            cargo
            rustToolchain
            cacert
            git
          ];

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = cargoDepsHash;

          buildPhase = ''
            cd apps/whispering/src-tauri
            export CARGO_HOME=$TMPDIR/cargo

            mkdir -p $out
            # Vendor dependencies to $out
            # We capture the config but replace the absolute path to avoid self-reference in FOD
            cargo vendor $out > config.toml
            sed -i "s|$out|@VENDOR@|g" config.toml
            install -Dm644 config.toml $out/config.toml
          '';

          installPhase = "true";
          dontFixup = true;
        };

        whispering = pkgs.stdenv.mkDerivation rec {
          pname = "whispering";
          inherit version src;

          inherit nativeBuildInputs buildInputs;

          # Disable default npm/node install hooks
          dontNpmInstall = true;

          # Environment variables for the build
          OPENSSL_NO_VENDOR = "1";
          OPENSSL_DIR = "${pkgs.openssl.dev}";
          OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";

          # For bindgen (whisper-rs-sys)
          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
          BINDGEN_EXTRA_CLANG_ARGS = "-I${pkgs.libclang.lib}/lib/clang/${pkgs.libclang.version}/include";

          # For webkit/gtk
          GIO_MODULE_DIR = "${pkgs.glib-networking}/lib/gio/modules";

          # Cargo configuration
          CARGO_HOME = "$TMPDIR/cargo";

          # Tauri/WebKit settings
          WEBKIT_DISABLE_COMPOSITING_MODE = "1";

          configurePhase = ''
            runHook preConfigure

            # Set up caches in temp directory
            export HOME=$TMPDIR
            export BUN_INSTALL=$TMPDIR/bun
            export npm_config_cache=$TMPDIR/npm-cache

            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild

            # Copy pre-fetched node_modules from the FOD
            cp -r ${npmDeps}/node_modules ./node_modules
            chmod -R u+w node_modules

            # Copy workspace node_modules if they exist
            if [ -d "${npmDeps}/apps" ]; then
              for app in ${npmDeps}/apps/*; do
                if [ -d "$app/node_modules" ]; then
                  appName=$(basename "$app")
                  if [ -d "apps/$appName" ]; then
                    echo "Copying node_modules for $appName"
                    cp -r "$app/node_modules" "apps/$appName/"
                    chmod -R u+w "apps/$appName/node_modules"
                  fi
                fi
              done
            fi

            # Copy packages node_modules if they exist
            if [ -d "${npmDeps}/packages" ]; then
              for pkg in ${npmDeps}/packages/*; do
                if [ -d "$pkg/node_modules" ]; then
                  pkgName=$(basename "$pkg")
                  if [ -d "packages/$pkgName" ]; then
                    echo "Copying node_modules for packages/$pkgName"
                    cp -r "$pkg/node_modules" "packages/$pkgName/"
                    chmod -R u+w "packages/$pkgName/node_modules"
                  fi
                fi
              done
            fi

            # Patch shebangs in node_modules to fix /usr/bin/env issues
            patchShebangs node_modules
            patchShebangs apps
            if [ -d "packages" ]; then
              patchShebangs packages
            fi

            # Add node_modules binaries to PATH
            export PATH="$PWD/node_modules/.bin:$PWD/apps/whispering/node_modules/.bin:$PATH"

            # Build the whispering frontend (SvelteKit)
            cd apps/whispering
            echo "Building frontend..."
            bun run build
            
            echo "Checking frontend build output..."
            ls -R build || echo "build dir not found"
            
            if [ ! -f build/index.html ]; then
              echo "CRITICAL ERROR: build/index.html missing! Frontend build failed or path is wrong."
              exit 1
            fi

            # Build Tauri/Rust backend
            cd src-tauri
            
            # Patch tauri.conf.json to ensure correct paths and no devUrl
            echo "Patching tauri.conf.json..."
            jq '.build.frontendDist = "../build" | .build.devUrl = null | .build.beforeBuildCommand = null | .build.beforeDevCommand = null' tauri.conf.json > tauri.conf.json.tmp && mv tauri.conf.json.tmp tauri.conf.json
            cat tauri.conf.json

            # Configure cargo
            mkdir -p .cargo
            cat > .cargo/config.toml << 'CARGOCONF'
            [net]
            offline = true

            [build]
            rustflags = ["-C", "link-arg=-Wl,-rpath,${libPath}"]
            CARGOCONF

            # Copy vendored dependencies to be writable (needed for tauri plugins that generate files)
            cp -r ${cargoDeps} vendor
            chmod -R u+w vendor

            # Append vendored dependencies config
            # Substitute the placeholder with the local path
            sed "s|@VENDOR@|$PWD/vendor|g" ${cargoDeps}/config.toml >> .cargo/config.toml
            
            # Build the release binary
            cargo build --release --bin whispering
            
            runHook postBuild
          '';

          installPhase = ''
                        runHook preInstall
                        
                        # Debug: find the binary
                        find . -name whispering -type f
                        
                        # Create output directories
                        mkdir -p $out/bin
                        mkdir -p $out/share/applications
                        mkdir -p $out/share/icons/hicolor/{32x32,128x128,256x256}/apps
                        mkdir -p $out/lib/whispering
                        
                        # Install the binary (use find to locate it robustly)
                        install -Dm755 $(find . -name whispering -type f | grep release | head -n 1) $out/bin/whispering
                        
                        # Install frontend build (Tauri embeds this, but useful for debugging)
                        if [ -d apps/whispering/build ]; then
                          mkdir -p $out/lib/whispering/frontend
                          cp -r apps/whispering/build/* $out/lib/whispering/frontend/
                          echo "Frontend build copied successfully."
                        else
                           echo "WARNING: apps/whispering/build not found in installPhase (pwd: $(pwd))"
                           # Try to list to see where we are
                           ls -la apps/whispering || true
                        fi
                        
                        # Install desktop entry
                        cat > $out/share/applications/whispering.desktop << EOF
            [Desktop Entry]
            Name=Whispering
            Comment=Open-source speech-to-text application - Press shortcut, speak, get text
            GenericName=Speech to Text
            Exec=$out/bin/whispering %U
            Icon=whispering
            Terminal=false
            Type=Application
            Categories=Audio;Utility;Accessibility;AudioVideo;
            Keywords=speech;transcription;whisper;voice;dictation;stt;
            StartupNotify=true
            StartupWMClass=whispering
            MimeType=audio/wav;audio/mpeg;audio/ogg;
            EOF
                        
                        # Install icons
                        for size in 32 128; do
                          if [ -f apps/whispering/src-tauri/icons/''${size}x''${size}.png ]; then
                            install -Dm644 apps/whispering/src-tauri/icons/''${size}x''${size}.png \
                              $out/share/icons/hicolor/''${size}x''${size}/apps/whispering.png
                          fi
                        done
                        
                        # Install high-res icon
                        if [ -f apps/whispering/src-tauri/icons/128x128@2x.png ]; then
                          install -Dm644 apps/whispering/src-tauri/icons/128x128@2x.png \
                            $out/share/icons/hicolor/256x256/apps/whispering.png
                        fi
                        
                        runHook postInstall
          '';

          # Wrap the binary with required library paths and environment
          preFixup = ''
            # Patch RPATH before wrapping
            # Find the binary - might be in .whispering-wrapped if wrapped earlier, or just whispering
            if [ -f $out/bin/whispering ]; then
               if file $out/bin/whispering | grep -q "ELF"; then
                 patchelf --set-rpath "${libPath}" $out/bin/whispering || true
               fi
            fi
          '';

          postFixup = ''
            # Verify frontend build exists
            if [ ! -f $out/lib/whispering/frontend/index.html ]; then
              echo "WARNING: Frontend build seems missing or incomplete!"
            fi

            # Wrap with environment variables
            wrapProgram $out/bin/whispering \
              --prefix LD_LIBRARY_PATH : "${libPath}" \
              --prefix GIO_MODULE_DIR : "${pkgs.glib-networking}/lib/gio/modules" \
              --set WEBKIT_DISABLE_COMPOSITING_MODE "1" \
              --set WEBKIT_DISABLE_DMABUF_RENDERER "1" \
              --set WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS "1" \
              --set RUST_BACKTRACE "1" \
              --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.ffmpeg ]}" \
              --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
              --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${
                pkgs.lib.makeSearchPath "lib/gstreamer-1.0" (
                  with pkgs.gst_all_1;
                  [
                    gstreamer
                    gst-plugins-base
                    gst-plugins-good
                    gst-plugins-bad
                    gst-plugins-ugly
                    gst-libav
                  ]
                )
              }"
          '';

          meta = with pkgs.lib; {
            description = "Open-source speech-to-text application with local and cloud transcription";
            longDescription = ''
              Whispering is an open-source speech-to-text application. Press a keyboard
              shortcut, speak, and your words will transcribe, transform, then copy and
              paste at the cursor. Supports multiple transcription providers including
              local (Whisper C++, Moonshine, Parakeet) and cloud (Groq, OpenAI, ElevenLabs).
            '';
            homepage = "https://whispering.epicenterhq.com";
            changelog = "https://github.com/EpicenterHQ/epicenter/releases";
            license = licenses.agpl3Plus;
            maintainers = [ ];
            platforms = platforms.linux;
            mainProgram = "whispering";
          };
        };

      in
      {
        packages = {
          default = whispering;
          inherit whispering;
        };

        # Development shell for contributing to Whispering
        devShells.default = pkgs.mkShell {
          inherit nativeBuildInputs buildInputs;

          shellHook = ''
            export LD_LIBRARY_PATH="${libPath}:$LD_LIBRARY_PATH"
            export GIO_MODULE_DIR="${pkgs.glib-networking}/lib/gio/modules"
            export OPENSSL_DIR="${pkgs.openssl.dev}"
            export OPENSSL_LIB_DIR="${pkgs.openssl.out}/lib"
            export WEBKIT_DISABLE_COMPOSITING_MODE=1
            export WEBKIT_DISABLE_DMABUF_RENDERER=1
            export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1

            echo "🎤 Whispering development environment loaded!"
            echo ""
            echo "Quick start:"
            echo "  1. Clone: git clone https://github.com/EpicenterHQ/epicenter.git"
            echo "  2. Install: cd epicenter && bun install"
            echo "  3. Develop: cd apps/whispering && bun tauri dev"
            echo ""
          '';
        };

        # For use with 'nix run'
        apps.default = {
          type = "app";
          program = "${whispering}/bin/whispering";
          meta = {
            description = "Open-source speech-to-text application";
          };
        };
      }
    )
    // {
      # ============================================================
      # NixOS Module
      # ============================================================
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.whispering;
        in
        {
          options.programs.whispering = {
            enable = lib.mkEnableOption "Whispering speech-to-text application";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.whispering;
              defaultText = lib.literalExpression "pkgs.whispering";
              description = "The Whispering package to use.";
            };

            autostart = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to autostart Whispering on login.";
            };

            enableGlobalShortcuts = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Enable support for global keyboard shortcuts.
                This adds the user to the 'input' group and sets up udev rules.
              '';
            };

            enablePipewire = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to enable PipeWire for audio support.";
            };
          };

          config = lib.mkIf cfg.enable {
            # Add package to system
            environment.systemPackages = [ cfg.package ];

            # Enable audio with PipeWire
            services.pipewire = lib.mkIf cfg.enablePipewire {
              enable = lib.mkDefault true;
              alsa.enable = lib.mkDefault true;
              pulse.enable = lib.mkDefault true;
            };

            # Enable D-Bus for notifications and system integration
            services.dbus.enable = true;

            # XDG autostart entry
            environment.etc = lib.mkIf cfg.autostart {
              "xdg/autostart/whispering.desktop".source = "${cfg.package}/share/applications/whispering.desktop";
            };

            # udev rules for input device access (global shortcuts)
            services.udev.extraRules = lib.mkIf cfg.enableGlobalShortcuts ''
              # Allow access to input devices for global keyboard shortcuts
              SUBSYSTEM=="input", GROUP="input", MODE="0660"
            '';

            # Ensure required groups exist
            users.groups.audio = { };
            users.groups.input = lib.mkIf cfg.enableGlobalShortcuts { };
          };
        };

      # ============================================================
      # Home Manager Module
      # ============================================================
      homeManagerModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.whispering;
        in
        {
          options.programs.whispering = {
            enable = lib.mkEnableOption "Whispering speech-to-text application";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.whispering;
              defaultText = lib.literalExpression "pkgs.whispering";
              description = "The Whispering package to use.";
            };

            autostart = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to autostart Whispering on login.";
            };

            settings = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
              description = ''
                Whispering configuration settings.
                Note: Whispering stores settings in IndexedDB, so this option
                is reserved for future configuration file support.
              '';
              example = lib.literalExpression ''
                {
                  # Reserved for future use
                }
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];

            # XDG autostart configuration
            xdg.configFile = lib.mkIf cfg.autostart {
              "autostart/whispering.desktop".source = "${cfg.package}/share/applications/whispering.desktop";
            };

            # Ensure XDG desktop entry is available
            xdg.desktopEntries.whispering = {
              name = "Whispering";
              comment = "Open-source speech-to-text application";
              genericName = "Speech to Text";
              exec = "${cfg.package}/bin/whispering %U";
              icon = "whispering";
              terminal = false;
              categories = [
                "Audio"
                "Utility"
                "Accessibility"
                "AudioVideo"
              ];
              mimeType = [
                "audio/wav"
                "audio/mpeg"
                "audio/ogg"
              ];
              startupNotify = true;
            };
          };
        };

      # ============================================================
      # Overlay
      # ============================================================
      overlays.default = final: prev: {
        whispering = self.packages.${prev.system}.whispering;
      };
    };
}
