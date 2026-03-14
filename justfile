set shell := ["bash", "-uc"]

# OS detection
os := if os_family() == "windows" { "windows" } else if os_family() == "macos" { "macos" } else { "linux" }

# Default recipe
default:
    @just --list

# Build the application for the current OS
build:
    @if [ "{{os}}" == "linux" ]; then \
        just build-linux; \
    elif [ "{{os}}" == "macos" ]; then \
        just build-macos; \
    fi

# Run the application for the current OS
run:
    @if [ "{{os}}" == "linux" ]; then \
        just run-linux; \
    elif [ "{{os}}" == "macos" ]; then \
        just run-macos; \
    fi

# Run all tests
test:
    cargo test --manifest-path syntax/Cargo.toml
    cargo test --manifest-path core/Cargo.toml
    @if [ "{{os}}" == "linux" ]; then \
        cargo test --manifest-path linux-ui/Cargo.toml; \
    fi

# --- Linux Specific ---

# Build Linux UI
build-linux:
    cargo build --release --manifest-path linux-ui/Cargo.toml

# Run Linux UI
run-linux:
    cargo run --release --manifest-path linux-ui/Cargo.toml

# Package Linux release artifacts (requires nfpm and linuxdeploy)
package-linux version: build-linux
    @if [ -z "${LINUXDEPLOY:-}" ]; then \
        echo "Error: LINUXDEPLOY environment variable must be set to the path of the linuxdeploy AppImage"; \
        exit 1; \
    fi
    bash build/linux/package-release.sh --version {{version}}

# --- macOS Specific ---

# Build macOS UI
build-macos: build-core-release
    swift build -c release --package-path macos-ui

# Package macOS release artifacts
package-macos version: build-macos
    bash build/macos/package-release.sh --version {{version}}

# Run macOS UI
run-macos: build-core-release
    swift run -c release --package-path macos-ui

# Build Rust core for macOS FFI
build-core-release:
    cargo build --release --manifest-path core/Cargo.toml

# --- Housekeeping ---

# Clean build artifacts
clean:
    cargo clean --manifest-path syntax/Cargo.toml
    cargo clean --manifest-path core/Cargo.toml
    cargo clean --manifest-path linux-ui/Cargo.toml
    rm -rf macos-ui/.build
    rm -rf dist/
