#!/usr/bin/env bash
set -euo pipefail
paper_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(dirname -- "$paper_dir")"
build_dir="$repo_dir/tmp/pdfs/build"
output_dir="$repo_dir/output/pdf"
mkdir -p "$build_dir" "$output_dir"
cd "$paper_dir"
if [[ -n "${TECTONIC:-}" ]]; then
  "$TECTONIC" --keep-logs --outdir "$build_dir" main.tex
elif command -v tectonic >/dev/null 2>&1; then
  tectonic --keep-logs --outdir "$build_dir" main.tex
elif command -v latexmk >/dev/null 2>&1; then
  latexmk -pdf -interaction=nonstopmode -halt-on-error -outdir="$build_dir" main.tex
else
  echo 'Install Tectonic or a TeX distribution with latexmk, or set TECTONIC to its executable path.' >&2
  exit 1
fi
cp "$build_dir/main.pdf" "$output_dir/architectural-incorrigibility.pdf"
echo "Built $output_dir/architectural-incorrigibility.pdf"
