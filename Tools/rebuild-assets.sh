#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
VENV="${PWD}/.build/asset-venv"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install -r Tools/requirements.txt
"$VENV/bin/python" Tools/prepare_assets.py
"$VENV/bin/python" Tools/make_icon.py
python3 Tools/generate_sounds.py
