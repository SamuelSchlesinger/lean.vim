#!/bin/sh
set -eu

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

check_hash() {
  license_path=$1
  license_expected=$2
  license_actual=$(sha256_file "$license_path")
  if test "$license_actual" != "$license_expected"; then
    echo "license provenance check failed for $license_path" >&2
    echo "expected $license_expected, got $license_actual" >&2
    exit 1
  fi
}

check_notice() {
  license_text=$1
  if ! grep -Fq "$license_text" NOTICE; then
    echo "NOTICE is missing required provenance: $license_text" >&2
    exit 1
  fi
}

# Exact MIT-licensed copies from lean.nvim e05c0f8.
check_hash data/lean/snippets.json 5b0d8cfee4f3d20e020e4fc7730f99abc5ad1c0f3f2f086dd0a91698e378b439
check_hash snippets/lean.json 5b0d8cfee4f3d20e020e4fc7730f99abc5ad1c0f3f2f086dd0a91698e378b439
check_hash syntax/lean.vim 7502c15a4e728c5c037fc2b9edd31ff4435828b20215a3c0f299a08745430879

# Exact Apache-2.0 abbreviation data and the canonical license text.
check_hash data/lean/abbreviations.json d5c529fdeb62071d6d16d51e3274a638165833a8c8cfdf02b379e051cbe22f27
check_hash LICENSES/Apache-2.0.txt 69849221bfb90053de2134ef5e6d540287b4b98062326492f1f96f5da685524b

check_notice e05c0f821412337259b98cc732ff0cf6ac7afe0c
check_notice 5a25e6abb2e973b4c89a053acc74c479c0bb2e9f
check_notice 'Copyright (c) 2020 Julian Berman'
check_notice 'licensed under Apache-2.0, not MIT'
