# #!/usr/bin/env bash
#
# SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
# # echo "$SCRIPT_DIR"
#
#
# confirm_action() {
#     while true; do
#         # Capital Y visually indicates it is the default choice
#         read -p "Do you want to proceed? [Y/n]: " yn
#
#         # ${yn:-Y} replaces an empty response (Enter) with 'Y'
#         case "${yn:-Y}" in
#             [Yy]* ) return 0;;
#             [Nn]* ) return 1;;
#             * ) echo "Invalid input. Please enter y or n.";;
#         esac
#     done
# }
#
#
#
# unset -v newest
# for file in ~/Downloads/*; do
#     [[ -f "$file" ]] || continue
#     [[ -z "$newest" || "$file" -nt "$newest" ]] && newest="$file"
# done
#
# echo "The newest file is: $newest"
# echo "The file will be moved to ~/Projects/custom_pdf_stuff/patches/"
#
#
# # if confirm_action; then
# #     echo "Proceeding..."
# # else
# #     echo "Aborting."
# #     exit
# # fi
# #
# # mv $newest /home/taylor/Projects/custom_pdf_stuff/patches/
# #
# # echo "File moved" \n
# #
# # echo "Extracting the zip"
# # ./home/taylor/dolphin-extract-flatten/dolphin-extract-flatten



#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Infinite Notes - Apply latest downloaded patch
# ------------------------------------------------------------

DOWNLOADS="$HOME/Downloads"
PATCHES_DIR="$HOME/Projects/custom_pdf_stuff/patches"

# Figure out the infinite-notes repo root based on this script's location.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if [[ ! -d "$REPO_ROOT/.git" ]]; then
    echo "Error: Could not find the infinite-notes git repository."
    echo "Expected repo root: $REPO_ROOT"
    exit 1
fi

mkdir -p "$PATCHES_DIR"

# ------------------------------------------------------------
# Find newest downloaded ZIP
# ------------------------------------------------------------

ZIP_FILE="$(
    find "$DOWNLOADS" -maxdepth 1 -type f -iname '*.zip' \
        -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    head -n 1 |
    cut -d' ' -f2-
)"

if [[ -z "${ZIP_FILE:-}" ]]; then
    echo "Error: No ZIP files found in:"
    echo "  $DOWNLOADS"
    exit 1
fi

ZIP_NAME="$(basename "$ZIP_FILE")"
PATCH_NAME="${ZIP_NAME%.zip}"

# Remove characters that would make the directory annoying to work with.
PATCH_NAME="$(printf '%s' "$PATCH_NAME" | tr ' ' '_')"

EXTRACT_DIR="$PATCHES_DIR/$PATCH_NAME"

echo
echo "Patch ZIP:"
echo "  $ZIP_FILE"
echo
echo "Repository:"
echo "  $REPO_ROOT"
echo
echo "Extracting to:"
echo "  $EXTRACT_DIR"
echo

# ------------------------------------------------------------
# Extract patch
# ------------------------------------------------------------

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

unzip -q "$ZIP_FILE" -d "$EXTRACT_DIR"

echo "Extraction successful."

# Only delete the ZIP after unzip succeeds.
rm "$ZIP_FILE"

echo "Deleted downloaded ZIP."

# ------------------------------------------------------------
# Find patch script
# ------------------------------------------------------------

# Sometimes a ZIP contains a single top-level directory, so search
# a few levels deep rather than assuming the script is at the root.

PATCH_SCRIPT=""

for candidate in \
    "apply_patch.sh" \
    "apply-patch.sh" \
    "patch.sh"
do
    PATCH_SCRIPT="$(
        find "$EXTRACT_DIR" -maxdepth 3 -type f -name "$candidate" \
            -print -quit
    )"

    if [[ -n "$PATCH_SCRIPT" ]]; then
        break
    fi
done

# If no standard name was found, use the only .sh file if exactly
# one exists.
if [[ -z "$PATCH_SCRIPT" ]]; then
    mapfile -t SHELL_SCRIPTS < <(
        find "$EXTRACT_DIR" -maxdepth 3 -type f -name '*.sh'
    )

    if [[ "${#SHELL_SCRIPTS[@]}" -eq 1 ]]; then
        PATCH_SCRIPT="${SHELL_SCRIPTS[0]}"
    fi
fi

if [[ -z "$PATCH_SCRIPT" ]]; then
    echo
    echo "Error: Patch extracted, but I couldn't identify the patch script."
    echo
    echo "Shell scripts found:"
    find "$EXTRACT_DIR" -maxdepth 3 -type f -name '*.sh' -print || true
    exit 1
fi

echo
echo "Patch script:"
echo "  $PATCH_SCRIPT"
echo

# ------------------------------------------------------------
# Run patch FROM the infinite-notes repository
# ------------------------------------------------------------

cd "$REPO_ROOT"

chmod +x "$PATCH_SCRIPT"

echo "Running patch from:"
echo "  $(pwd)"
echo
echo "------------------------------------------------------------"

"$PATCH_SCRIPT"

echo "------------------------------------------------------------"
echo
echo "Patch completed successfully."
echo
