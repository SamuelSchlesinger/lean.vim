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
# MIT-licensed from lean.nvim e05c0f8, modified as described in NOTICE
# (global markdown highlight overrides removed).
check_hash syntax/lean.vim bf781c19cff402aa21f327758f561dcfa198562fb0b5da54a5d2fd3c952f42e3

# Exact Apache-2.0 abbreviation data and the canonical license text.
check_hash data/lean/abbreviations.json fa5e317d4d481c8bf12d6438e489376931c18438dd0a68af3683a4cb9e92b5b0
check_hash LICENSES/Apache-2.0.txt 69849221bfb90053de2134ef5e6d540287b4b98062326492f1f96f5da685524b

check_notice e05c0f821412337259b98cc732ff0cf6ac7afe0c
check_notice 527b47e8a2f61968e6af55ad4c5550e70e5b9555
check_notice dead846a035f42dc13beb7619ac779538e6ddf6e
check_notice 'Copyright (c) 2020 Julian Berman'
check_notice 'licensed under Apache-2.0, not MIT'
