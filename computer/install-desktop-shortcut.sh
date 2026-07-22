#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
root="$(pwd -P)"
bin_dir="$HOME/.local/bin"
app_dir="$HOME/.local/share/applications"
launcher="$bin_dir/infinite-notes"
desktop="$app_dir/infinite-notes.desktop"

mkdir -p "$bin_dir" "$app_dir"

# Remove version-specific launchers from older bundles.
rm -f "$bin_dir/infinite-notes-v14" "$bin_dir/infinite-notes-v15"
rm -f "$app_dir/infinite-notes-v14.desktop" "$app_dir/infinite-notes-v15.desktop"

printf '#!/usr/bin/env bash\ncd %q\nexec ./run.sh\n' "$root" > "$launcher"
chmod +x "$launcher"

cat > "$desktop" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=Infinite Notes
Comment=Start NotesHotspot and the Infinite Notes server
Exec=$launcher
Icon=$root/static/icon-512.png
Terminal=true
Categories=Office;Education;
StartupNotify=true
EOF_DESKTOP
chmod 0644 "$desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$app_dir" >/dev/null 2>&1 || true
fi

echo "Installed application shortcut: Infinite Notes"
echo "Desktop file: $desktop"
echo "Closing its terminal with Ctrl+C stops both the app and NotesHotspot."
