#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/venv"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "python3 was not found. Please install Python 3 first." >&2
  exit 1
fi

echo "[1/5] Installing OS packages (may prompt for sudo password)..."
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip ca-certificates

echo "[2/5] Creating virtual environment..."
"$PYTHON_BIN" -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

echo "[3/5] Installing Python packages..."
pip install --upgrade pip setuptools wheel
pip install playwright beautifulsoup4 lxml

echo "[4/5] Installing Chromium + required system dependencies via Playwright..."
python -m playwright install --with-deps chromium

echo "[5/5] Done."
echo

echo "Examples:"
echo "  source '$VENV_DIR/bin/activate'"
echo "  python '$SCRIPT_DIR/url_to_txt.py' --input '$SCRIPT_DIR/urls.txt' --output '$SCRIPT_DIR/out' --format md"
echo "  python '$SCRIPT_DIR/url_to_txt.py' --csv-input '$SCRIPT_DIR/urls.csv' --csv-column url --output '$SCRIPT_DIR/out' --csv-report '$SCRIPT_DIR/report.csv'"
