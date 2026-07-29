#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
# echo "$SCRIPT_DIR"


confirm_action() {
    while true; do
        # Capital Y visually indicates it is the default choice
        read -p "Do you want to proceed? [Y/n]: " yn

        # ${yn:-Y} replaces an empty response (Enter) with 'Y'
        case "${yn:-Y}" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Invalid input. Please enter y or n.";;
        esac
    done
}



unset -v newest
for file in ~/Downloads/*; do
    [[ -f "$file" ]] || continue
    [[ -z "$newest" || "$file" -nt "$newest" ]] && newest="$file"
done

echo "The newest file is: $newest"
echo "The file will be moved to ~/Projects/custom_pdf_stuff/patches/"


# if confirm_action; then
#     echo "Proceeding..."
# else
#     echo "Aborting."
#     exit
# fi
#
# mv $newest /home/taylor/Projects/custom_pdf_stuff/patches/
#
# echo "File moved" \n
#
# echo "Extracting the zip"
# ./home/taylor/dolphin-extract-flatten/dolphin-extract-flatten
