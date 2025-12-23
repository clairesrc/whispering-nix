# Agents Guide for whispering-nix

## Project Context
This is a **Nix flake repository** that packages the [Whispering](https://github.com/EpicenterHQ/epicenter/tree/main/apps/whispering) application.

**Crucial**: The application source code is **NOT** hosted in this repository. It is fetched from the upstream GitHub repository during the Nix build process.
Tasks in this repository involve maintaining the Nix packaging logic, updating versions/hashes, and fixing build environment issues.

## Key Files
- **`flake.nix`**: The main entry point. Defines:
  - `npmDeps`: A fixed-output derivation that pre-fetches Node.js dependencies.
  - `cargoDeps`: A fixed-output derivation that pre-fetches Rust/Cargo dependencies.
  - `whispering`: The actual package derivation that combines source + deps + build steps.
  - `nixosModules` & `homeManagerModules`: Configuration modules for users.
- **`README.md`**: User-facing documentation.

## Common Commands

### Build
```bash
nix build
```
This produces the artifact in `./result`.

### Run
```bash
nix run
```
Builds and executes the binary immediately.

### Development Shell
```bash
nix develop
```
Enters a shell with all build dependencies (Rust, Node, system libraries) and environment variables (LD_LIBRARY_PATH, etc.) pre-configured.

## Updating the Package
When the upstream `whispering` application releases a new version, follow this specific order:

1.  **Update Version**: Change the `version` variable in `flake.nix`.
2.  **Update Source Hash (`srcHash`)**:
    Run the prefetch command to get the new SHA256:
    ```bash
    nix-prefetch-github EpicenterHQ epicenter --rev main
    # Or for a specific tag: --rev v7.11.0
    ```
    Update `srcHash` in `flake.nix`.

3.  **Update Dependency Hashes**:
    The build uses "Fixed-Output Derivations" (FODs) to handle network-dependent steps (npm install, cargo vendor). When dependencies change, these hashes MUST change.
    
    **Strategy**:
    1.  Set `npmDepsHash` to an empty or dummy string (e.g., `"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="`).
    2.  Run `nix build`. It will fail and report the *actual* hash.
    3.  Update `npmDepsHash` with the reported hash.
    4.  Repeat steps 1-3 for `cargoDepsHash`.

## Build Architecture Notes
-   **Sandboxing**: The main `buildPhase` has **NO network access**. All dependencies must be present in `npmDeps` or `cargoDeps`.
-   **Vendoring**:
    -   Node modules are copied from the `npmDeps` output.
    -   Cargo crates are vendored into the `cargoDeps` output, and a `.cargo/config.toml` is generated to point to them.
-   **Environment**: The build relies on specific env vars like `OPENSSL_NO_VENDOR`, `WEBKIT_DISABLE_COMPOSITING_MODE`, and patched `LD_LIBRARY_PATH` for the runtime.

## Recent Build Fixes & Gotchas
-   **Vulkan/Shaderc**: `whisper-rs` (via `ggml`) requires `vulkan-headers`, `vulkan-loader`, and `shaderc` to build.
-   **Bindgen**: Requires `LIBCLANG_PATH` and `BINDGEN_EXTRA_CLANG_ARGS` pointing to `pkgs.libclang`.
-   **Writable Vendor Dir**: Some tauri plugins (e.g., `tauri-plugin-aptabase`) try to generate files inside the cargo vendor directory during build. We must `cp -r` the vendored deps to a local `vendor` dir and make it writable (`chmod -R u+w`).
-   **Binary Location**: `cargo build --release` inside `src-tauri` puts the binary at `target/release/whispering`. Ensure `installPhase` uses the correct path.

## Troubleshooting
-   **Hash Mismatch Errors**: This is normal during updates. Use the error output to find the new hash.
-   **Network Unreachable**: If the build tries to reach the network (e.g., `bun install` or `cargo build` trying to fetch registry info), it means the vendoring step failed or isn't being used correctly. Ensure `offline = true` is set in cargo config and `bun install --frozen-lockfile` uses the vendored `node_modules`.
