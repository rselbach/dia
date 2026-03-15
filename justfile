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
    @if [ "{{os}}" == "linux" ]; then \
        cd linux && go test ./...; \
    elif [ "{{os}}" == "macos" ]; then \
        swift test --package-path macos-ui; \
    fi

# --- Linux Specific ---

# Build Linux UI
build-linux:
    cd linux && go build -o ../dist/dia .

# Run Linux UI
run-linux:
    cd linux && go run .

# Package Linux release artifacts (requires nfpm and linuxdeploy)
package-linux version: build-linux
    @if [ -z "${LINUXDEPLOY:-}" ]; then \
        echo "Error: LINUXDEPLOY environment variable must be set to the path of the linuxdeploy AppImage"; \
        exit 1; \
    fi
    bash build/linux/package-release.sh --version {{version}}

# --- macOS Specific ---

# Build macOS UI
build-macos:
    swift build -c release --package-path macos-ui

# Package macOS release artifacts
package-macos version: build-macos
    bash build/macos/package-release.sh --version {{version}}

# Run macOS UI
run-macos:
    swift run -c release --package-path macos-ui

# --- Release ---

# Tag a new release by bumping the patch version
release:
    #!/usr/bin/env bash
    set -euo pipefail
    latest=$(git tag --sort=-v:refname | head -1)
    if [[ -z "${latest}" ]]; then
        echo "No existing tags found" >&2
        exit 1
    fi
    version="${latest#v}"
    IFS='.' read -r major minor patch <<< "${version}"
    new_patch=$((patch + 1))
    new_tag="v${major}.${minor}.${new_patch}"
    echo "Tagging ${new_tag} (was ${latest})"
    git tag "${new_tag}"
    echo "Done. Push with: git push origin ${new_tag}"

# --- Housekeeping ---

# Clean build artifacts
clean:
    rm -rf macos-ui/.build
    rm -rf dist/
