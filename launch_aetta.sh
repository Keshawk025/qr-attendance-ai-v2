#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEACHER_DIR="$ROOT_DIR/teacher-desktop"

cd "$TEACHER_DIR"
npm start
