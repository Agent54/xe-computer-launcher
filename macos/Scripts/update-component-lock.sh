#!/usr/bin/env bash

set -euo pipefail

component="${1:?usage: update-component-lock.sh COMPONENT [RELEASE_TAG]}"
requested_tag="${2:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="${XE_LAUNCHER_ROOT:-$(cd "$script_dir/../.." && pwd)}"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "$1 is required to update launcher components" >&2
        exit 1
    }
}

lock_value() {
    local key="$1"
    local file="$2"
    local value

    value="$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file")"
    [[ -n "$value" ]] || {
        echo "Missing $key in $file" >&2
        exit 1
    }
    printf '%s\n' "$value"
}

replace_lock_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    local output="$temporary_dir/$(basename "$file").updated"
    local found="false"
    local line

    : > "$output"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$key="* ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$output"
            found="true"
        else
            printf '%s\n' "$line" >> "$output"
        fi
    done < "$file"

    [[ "$found" == "true" ]] || {
        echo "Missing $key in $file" >&2
        exit 1
    }
    mv "$output" "$file"
}

release_has_asset() {
    local release_file="$1"
    local asset="$2"
    jq -e --arg asset "$asset" 'any(.assets[]; .name == $asset)' "$release_file" >/dev/null
}

download_asset() {
    local repository="$1"
    local tag="$2"
    local asset="$3"
    local destination="$temporary_dir/$asset"

    gh release download "$tag" \
        --repo "$repository" \
        --pattern "$asset" \
        --output "$destination" \
        --clobber
    [[ -s "$destination" ]] || {
        echo "Downloaded asset is missing or empty: $asset" >&2
        exit 1
    }
    printf '%s\n' "$destination"
}

asset_sha256() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

verify_published_checksum() {
    local repository="$1"
    local tag="$2"
    local manifest_asset="$3"
    local asset="$4"
    local actual="$5"
    local manifest_path
    local expected
    local expected_lower

    manifest_path="$(download_asset "$repository" "$tag" "$manifest_asset")"
    expected="$(awk -v asset="$asset" '
        {
            filename = $2
            sub(/^\*/, "", filename)
            if (filename == asset) {
                print $1
                exit
            }
        }
    ' "$manifest_path")"

    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || {
        echo "No valid checksum for $asset in $manifest_asset" >&2
        exit 1
    }
    expected_lower="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
    [[ "$expected_lower" == "$actual" ]] || {
        echo "Published checksum mismatch for $asset" >&2
        echo "expected: $expected_lower" >&2
        echo "actual:   $actual" >&2
        exit 1
    }
}

write_output() {
    local key="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
}

require_command gh
require_command jq
require_command shasum

case "$component" in
    xe-computer)
        display_name="Xe Computer"
        repository="Agent54/xe-darc"
        lock_file="macos/Sources/macos/Resources/sources.json"
        current_version="$(jq -er '.darc.version | [.major, .minor, .patch] | map(tostring) | join(".")' "$repository_root/$lock_file")"
        current_tag="v$current_version"
        tag_pattern='^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'
        primary_asset="darc.swbn"
        build_target="build"
        if [[ -n "$requested_tag" && "$requested_tag" != v* ]]; then
            requested_tag="v$requested_tag"
        fi
        ;;
    compose-server)
        display_name="Compose Server"
        repository="$(lock_value COMPOSE_SERVER_GITHUB_REPOSITORY "$repository_root/macos/ComposeServer.lock")"
        lock_file="macos/ComposeServer.lock"
        current_tag="$(lock_value COMPOSE_SERVER_RELEASE_TAG "$repository_root/$lock_file")"
        tag_pattern='^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})-int\.[0-9]+$'
        primary_asset="$(lock_value COMPOSE_SERVER_ASSET "$repository_root/$lock_file")"
        build_target="compose-server"
        ;;
    compose-ui)
        display_name="Compose UI"
        repository="$(lock_value COMPOSE_UI_GITHUB_REPOSITORY "$repository_root/macos/ComposeUI.lock")"
        lock_file="macos/ComposeUI.lock"
        current_tag="$(lock_value COMPOSE_UI_RELEASE_TAG "$repository_root/$lock_file")"
        tag_pattern='^int-[0-9]+-[0-9a-f]+$'
        primary_asset="$(lock_value COMPOSE_UI_ASSET "$repository_root/$lock_file")"
        build_target="compose-ui"
        ;;
    smolvm)
        display_name="SmolVM"
        repository="$(lock_value SMOLVM_GITHUB_REPOSITORY "$repository_root/macos/SmolVM.lock")"
        lock_file="macos/SmolVM.lock"
        current_tag="$(lock_value SMOLVM_RELEASE_TAG "$repository_root/$lock_file")"
        tag_pattern='^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})-compose_[0-9]+$'
        primary_asset=""
        build_target="smol-runtime"
        ;;
    *)
        echo "Unsupported component: $component" >&2
        exit 1
        ;;
esac

releases_file="$temporary_dir/releases.json"
gh api "repos/$repository/releases?per_page=100" > "$releases_file"

if [[ -n "$requested_tag" ]]; then
    release_tag="$requested_tag"
    jq -ec --arg tag "$release_tag" '.[] | select(.tag_name == $tag)' "$releases_file" > "$temporary_dir/release.json" || {
        echo "Release $release_tag was not found in the latest 100 releases for $repository" >&2
        exit 1
    }
else
    jq -ec --arg pattern "$tag_pattern" '
        first(.[] | select(
            .draft == false and
            .prerelease == true and
            (.tag_name | test($pattern))
        ))
    ' "$releases_file" > "$temporary_dir/release.json"
    release_tag="$(jq -r '.tag_name' "$temporary_dir/release.json")"
fi

release_file="$temporary_dir/release.json"
release_id="$(jq -er '.id' "$release_file")"
# The release-list response can retain an empty asset array after assets have
# been uploaded. Fetch assets from their dedicated endpoint instead.
gh api --paginate --slurp "repos/$repository/releases/$release_id/assets?per_page=100" \
    | jq 'add' > "$temporary_dir/assets.json"
jq --slurpfile assets "$temporary_dir/assets.json" '.assets = $assets[0]' \
    "$release_file" > "$temporary_dir/release-with-assets.json"
release_file="$temporary_dir/release-with-assets.json"
jq -e --arg pattern "$tag_pattern" '
    .draft == false and
    .prerelease == true and
    (.tag_name | test($pattern))
' "$release_file" >/dev/null || {
    echo "Release $release_tag is not an accepted published integration release for $component" >&2
    exit 1
}

if [[ "$component" == "smolvm" ]]; then
    [[ "$release_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-compose_[0-9]+$ ]] || {
        echo "Could not derive the SmolVM version from $release_tag" >&2
        exit 1
    }
    smolvm_version="${BASH_REMATCH[1]}"
    runtime_asset="smolvm-${smolvm_version}-darwin-arm64.tar.gz"
    compose_asset="smolvm-${smolvm_version}-docker-compose-darwin-arm64.smolmachine"
    release_has_asset "$release_file" "$runtime_asset"
    release_has_asset "$release_file" "$compose_asset"
    release_has_asset "$release_file" checksums.sha256 || {
        echo "Release $release_tag does not contain checksums.sha256" >&2
        exit 1
    }
else
    release_has_asset "$release_file" "$primary_asset" || {
        echo "Release $release_tag does not contain $primary_asset" >&2
        exit 1
    }
fi

if [[ "$release_tag" == "$current_tag" ]]; then
    echo "$display_name is already pinned to $release_tag"
    write_output updated false
    write_output component "$component"
    write_output display_name "$display_name"
    write_output release_tag "$release_tag"
    write_output repository "$repository"
    write_output lock_file "$lock_file"
    write_output build_target "$build_target"
    exit 0
fi

current_published_at="$(jq -er --arg tag "$current_tag" '.[] | select(.tag_name == $tag) | .published_at' "$releases_file")" || {
    echo "Current release $current_tag was not found for $repository; refusing an unverified replacement" >&2
    exit 1
}
candidate_published_at="$(jq -er '.published_at' "$release_file")"
if [[ "$candidate_published_at" < "$current_published_at" || "$candidate_published_at" == "$current_published_at" ]]; then
    echo "Refusing to replace $current_tag with non-newer release $release_tag" >&2
    exit 1
fi

case "$component" in
    xe-computer)
        version="${release_tag#v}"
        IFS=. read -r version_major version_minor version_patch <<< "$version"
        updated_sources="$temporary_dir/sources.json"
        jq --indent 4 \
            --argjson major "$version_major" \
            --argjson minor "$version_minor" \
            --argjson patch "$version_patch" \
            '.darc.version = {major: $major, minor: $minor, patch: $patch}' \
            "$repository_root/$lock_file" > "$updated_sources"
        mv "$updated_sources" "$repository_root/$lock_file"
        ;;
    compose-server)
        asset_path="$(download_asset "$repository" "$release_tag" "$primary_asset")"
        checksum="$(asset_sha256 "$asset_path")"
        if release_has_asset "$release_file" "${primary_asset}.sha256"; then
            verify_published_checksum "$repository" "$release_tag" "${primary_asset}.sha256" "$primary_asset" "$checksum"
        fi
        replace_lock_value COMPOSE_SERVER_RELEASE_TAG "$release_tag" "$repository_root/$lock_file"
        replace_lock_value COMPOSE_SERVER_SHA256 "$checksum" "$repository_root/$lock_file"
        ;;
    compose-ui)
        asset_path="$(download_asset "$repository" "$release_tag" "$primary_asset")"
        checksum="$(asset_sha256 "$asset_path")"
        release_has_asset "$release_file" SHA256SUMS || {
            echo "Release $release_tag does not contain SHA256SUMS" >&2
            exit 1
        }
        verify_published_checksum "$repository" "$release_tag" SHA256SUMS "$primary_asset" "$checksum"
        replace_lock_value COMPOSE_UI_RELEASE_TAG "$release_tag" "$repository_root/$lock_file"
        replace_lock_value COMPOSE_UI_SHA256 "$checksum" "$repository_root/$lock_file"
        ;;
    smolvm)
        runtime_path="$(download_asset "$repository" "$release_tag" "$runtime_asset")"
        compose_path="$(download_asset "$repository" "$release_tag" "$compose_asset")"
        runtime_checksum="$(asset_sha256 "$runtime_path")"
        compose_checksum="$(asset_sha256 "$compose_path")"
        verify_published_checksum "$repository" "$release_tag" checksums.sha256 "$runtime_asset" "$runtime_checksum"
        verify_published_checksum "$repository" "$release_tag" checksums.sha256 "$compose_asset" "$compose_checksum"
        replace_lock_value SMOLVM_VERSION "$smolvm_version" "$repository_root/$lock_file"
        replace_lock_value SMOLVM_RELEASE_TAG "$release_tag" "$repository_root/$lock_file"
        replace_lock_value SMOLVM_RUNTIME_SHA256 "$runtime_checksum" "$repository_root/$lock_file"
        replace_lock_value SMOLVM_COMPOSE_SHA256 "$compose_checksum" "$repository_root/$lock_file"
        ;;
esac

echo "Updated $display_name from $current_tag to $release_tag"
write_output updated true
write_output component "$component"
write_output display_name "$display_name"
write_output release_tag "$release_tag"
write_output repository "$repository"
write_output lock_file "$lock_file"
write_output build_target "$build_target"
