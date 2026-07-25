#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "${PROJECT_ROOT}/Scripts/build-unsigned-ipa.sh"
