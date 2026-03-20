set shell := ["bash", "-uc"]

mermaid_version := "11.13.0"
mermaid_url := "https://cdn.jsdelivr.net/npm/mermaid@" + mermaid_version + "/dist/mermaid.min.js"
mermaid_path := "vendor-js/mermaid.min.js"

# Default recipe
default:
    @just --list

# Download the mermaid.js bundle
mermaid:
    @if [ ! -f "{{mermaid_path}}" ]; then \
        echo "Downloading mermaid {{mermaid_version}}..."; \
        mkdir -p vendor-js; \
        curl -fsSL -o "{{mermaid_path}}" "{{mermaid_url}}"; \
    else \
        echo "mermaid {{mermaid_version}} already downloaded"; \
    fi

# Build the application
build: mermaid
    go build -o dist/dia .

# Run the application
run: mermaid
    go run .

# Run all tests
test:
    go test ./...

# Package release artifacts (requires nfpm and linuxdeploy)
package version: build
    @if [ -z "${LINUXDEPLOY:-}" ]; then \
        echo "Error: LINUXDEPLOY environment variable must be set to the path of the linuxdeploy AppImage"; \
        exit 1; \
    fi
    bash build/package-release.sh --version {{version}}

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

# Clean build artifacts
clean:
    rm -rf dist/
