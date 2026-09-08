#!/usr/bin/env bash
# Build on Linux ARM64. Ship the executable and its runtime files, not an image.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)/$(uname -m)" == Linux/aarch64 ]] || {
    echo 'Build the guest runtime on Linux ARM64, or use the guest-worker CI artifact.' >&2
    exit 1
}
destination=dist/guest-runtime
mkdir -p "$destination/lib" "$destination/licenses"
cp node_modules/workerd/bin/workerd "$destination/workerd"
cp dist/guest-worker.bin "$destination/guest-worker.bin"
cp docker/run.sh docker/stop.sh "$destination/"
cp node_modules/workerd/README.md "$destination/licenses/workerd-README.md"
# Include the shared libraries and loader used by this exact Linux executable.
ldd "$destination/workerd" > dist/guest-runtime.ldd
if grep -q 'not found' dist/guest-runtime.ldd; then
    cat dist/guest-runtime.ldd >&2
    exit 1
fi
while IFS= read -r library; do
    cp -L "$library" "$destination/lib/"
done < <(awk '/=> \// {print $3} $1 ~ /^\// {print $1}' dist/guest-runtime.ldd)
for package in libc6 libgcc-s1 libstdc++6; do
    cp "/usr/share/doc/$package/copyright" "$destination/licenses/$package.txt"
done
chmod 755 "$destination/workerd" "$destination/lib/ld-linux-aarch64.so.1"
"$destination/lib/ld-linux-aarch64.so.1" --library-path "$destination/lib" "$destination/workerd" --version
cd "$destination"
sha256sum workerd guest-worker.bin lib/* licenses/* run.sh stop.sh > checksums.txt
