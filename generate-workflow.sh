#!/usr/bin/env bash
set -euo pipefail

# generate-workflow.sh — Generate a GitHub Actions CI workflow from a Rocq Platform package pick
#
# Usage:
#   ./generate-workflow.sh <package-pick-file.sh>
#   ./generate-workflow.sh --url <version>   (e.g. --url 9.0~2025.08)

##############################################################################
# Configuration
##############################################################################

# OCaml packages to exclude from the dependency graph (not Rocq/Coq packages)
EXCLUDED_PACKAGES=(
  ocamlfind dune dune-configurator sexplib sexplib0 elpi menhir gappa eprover
  z3_tptp ott ppx_optcomp
)

##############################################################################
# Helpers
##############################################################################

die() { echo "Error: $*" >&2; exit 1; }

is_excluded() {
  local name="$1"
  for exc in "${EXCLUDED_PACKAGES[@]}"; do
    [[ "$name" == "$exc" ]] && return 0
  done
  return 1
}

# Sanitize a package name for use as a YAML job id (lowercase, alphanumeric + hyphens)
job_id() {
  echo "$1" | tr '.' '-' | tr '_' '-' | tr '[:upper:]' '[:lower:]'
}

##############################################################################
# Parse arguments
##############################################################################

PICK_FILE=""

if [[ "${1:-}" == "--url" ]]; then
  VERSION="${2:?Missing version argument for --url}"
  PICK_FILE=$(mktemp /tmp/package-pick-XXXXXX.sh)
  URL="https://raw.githubusercontent.com/coq/platform/main/package_picks/package-pick-${VERSION}.sh"
  echo "Downloading package pick from $URL ..."
  curl -fsSL "$URL" -o "$PICK_FILE" || die "Failed to download $URL"
  trap "rm -f '$PICK_FILE'" EXIT
else
  PICK_FILE="${1:?Usage: $0 <package-pick.sh> | $0 --url <version>}"
  [[ -f "$PICK_FILE" ]] || die "File not found: $PICK_FILE"
fi

##############################################################################
# Step 1: Extract OCaml version
##############################################################################

OCAML_VERSION=$(grep -oP 'COQ_PLATFORM_OCAML_VERSION="\K[^"]+' "$PICK_FILE" || echo "4.14.2")
echo "OCaml version: $OCAML_VERSION"

##############################################################################
# Step 2: Extract version postfix for naming
##############################################################################

VERSION_POSTFIX=$(grep -oP 'COQ_PLATFORM_PACKAGE_PICK_POSTFIX="\K[^"]+' "$PICK_FILE" || echo "unknown")
echo "Version postfix: $VERSION_POSTFIX"

##############################################################################
# Step 3: Parse packages from the pick file
#
# Strategy: preprocess the file to remove conditional blocks we want to skip,
# then extract all PACKAGES="${PACKAGES} ..." tokens.
##############################################################################

echo "Parsing package pick..."

parse_packages() {
  local file="$1"

  # We use awk to filter out:
  # 1. Blocks inside "if false" ... "fi"
  # 2. Content inside case blocks for COMPCERT/UNIMATH/FIATCRYPTO
  # 3. The "extended" section (EXTENT =~ ^[xX])
  # Then we extract PACKAGES lines and parse tokens.

  awk '
    BEGIN { skip = 0; extended = 0 }

    # Skip "if false" blocks
    /^[[:space:]]*if false/ { skip++; next }
    skip > 0 && /^[[:space:]]*fi/ { skip--; next }
    skip > 0 { next }

    # Skip case blocks for optional packages
    /case "\$COQ_PLATFORM_UNIMATH"/ { skip++; next }
    /case "\$COQ_PLATFORM_COMPCERT"/ { skip++; next }
    /case "\$COQ_PLATFORM_VST"/ { skip++; next }
    /case "\$COQ_PLATFORM_FIATCRYPTO"/ { skip++; next }
    skip > 0 && /esac/ { skip--; next }
    skip > 0 { next }

    # Skip extended section
    /COQ_PLATFORM_EXTENT.*\^\[xX\]/ { extended = 1; next }
    extended && /^fi/ { extended = 0; next }
    extended { next }

    # Extract PACKAGES lines
    /PACKAGES="\$\{PACKAGES\}/ { print }
  ' "$file" \
  | grep -oP '(?<=PACKAGES="\$\{PACKAGES\} )[^"]+' \
  | tr ' ' '\n' \
  | while read -r token; do
      [[ -z "$token" ]] && continue
      # PIN.name.version → name.version (strip PIN prefix)
      if [[ "$token" == PIN.* ]]; then
        token="${token#PIN.}"
      fi
      echo "$token"
    done
}

# Build associative arrays: name→version, name.version list
declare -A PKG_VERSION  # name → version
declare -a PKG_LIST     # ordered list of name.version

while read -r nv; do
  # Split name.version — package names can contain hyphens, the version starts after last dot-separated numeric
  # Actually opam convention: name.version where version starts at first digit-segment after a dot
  # We need to handle e.g. coq-mathcomp-ssreflect.2.4.0 → name=coq-mathcomp-ssreflect, version=2.4.0
  # Also: coq.9.0.1 → name=coq, version=9.0.1
  # Strategy: find the first dot followed by a digit
  if [[ "$nv" =~ ^([a-zA-Z][a-zA-Z0-9_-]*)\.([0-9v].*)$ ]]; then
    name="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
  else
    echo "Warning: cannot parse '$nv', skipping" >&2
    continue
  fi
  PKG_VERSION["$name"]="$version"
  PKG_LIST+=("$name")
done < <(parse_packages "$PICK_FILE")

echo "Found ${#PKG_LIST[@]} packages"

# Build a set for quick membership check
declare -A PKG_SET
for name in "${PKG_LIST[@]}"; do
  PKG_SET["$name"]=1
done

# Build a mapping for coq↔rocq name variants to handle transitional packages
# e.g. "rocq-mathcomp-ssreflect" → "coq-mathcomp-ssreflect" if the latter is in pick
declare -A NAME_ALIAS
for name in "${PKG_LIST[@]}"; do
  # coq-X → rocq-X alias
  if [[ "$name" == coq-* ]]; then
    alt="rocq-${name#coq-}"
    NAME_ALIAS["$alt"]="$name"
  elif [[ "$name" == rocq-* ]]; then
    alt="coq-${name#rocq-}"
    NAME_ALIAS["$alt"]="$name"
  fi
  # coq ↔ rocq-core: the "coq" metapackage bundles rocq-core, so
  # dependencies on "rocq-core" or "coq-core" should resolve to "coq" if
  # "coq" is in the pick. But do NOT alias "coq" → "rocq-core" to avoid
  # cycles (rocq-stdlib depends on rocq-core which would map back to coq).
  if [[ "$name" == "coq" ]]; then
    NAME_ALIAS["rocq-core"]="coq"
    NAME_ALIAS["coq-core"]="coq"
  fi
done

# Resolve a dependency name to a pick package name (or empty if not in pick)
resolve_dep() {
  local dep="$1"
  if [[ -n "${PKG_SET[$dep]:-}" ]]; then
    echo "$dep"
  elif [[ -n "${NAME_ALIAS[$dep]:-}" ]]; then
    echo "${NAME_ALIAS[$dep]}"
  fi
}

##############################################################################
# Step 4: Resolve dependencies via opam
##############################################################################

echo "Resolving dependencies via opam..."

declare -A PKG_DEPS  # name → space-separated list of dependency names (within pick)

resolve_pkg_deps() {
  local raw_deps="$1"
  # Extract all quoted package names from opam depends output
  echo "$raw_deps" | grep -oP '"[a-zA-Z][a-zA-Z0-9_-]*"' | tr -d '"' | sort -u
}

for name in "${PKG_LIST[@]}"; do
  version="${PKG_VERSION[$name]}"

  # Query opam for dependencies
  raw_deps=$(opam info --field depends: "$name.$version" 2>/dev/null || echo "")

  # Parse dependency names and resolve against the pick
  dep_names=()
  declare -A seen_deps=()
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    resolved=$(resolve_dep "$dep")
    if [[ -n "$resolved" && -z "${seen_deps[$resolved]:-}" && "$resolved" != "$name" ]]; then
      dep_names+=("$resolved")
      seen_deps["$resolved"]=1
    fi
  done < <(resolve_pkg_deps "$raw_deps")

  # For transitional coq-* packages that only depend on rocq-*, also resolve
  # the deps of the rocq-* variant to get real dependencies
  if [[ "$name" == coq-* && ${#dep_names[@]} -le 1 ]]; then
    rocq_variant="rocq-${name#coq-}"
    rocq_deps=$(opam info --field depends: "$rocq_variant.$version" 2>/dev/null || echo "")
    if [[ -n "$rocq_deps" ]]; then
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        resolved=$(resolve_dep "$dep")
        if [[ -n "$resolved" && -z "${seen_deps[$resolved]:-}" && "$resolved" != "$name" ]]; then
          dep_names+=("$resolved")
          seen_deps["$resolved"]=1
        fi
      done < <(resolve_pkg_deps "$rocq_deps")
    fi
  fi
  unset seen_deps

  PKG_DEPS["$name"]="${dep_names[*]:-}"

  if [[ -n "${dep_names[*]:-}" ]]; then
    echo "  $name → ${dep_names[*]}"
  else
    echo "  $name → (no deps in pick)"
  fi
done

##############################################################################
# Step 4b: Break dependency cycles
#
# The coq/rocq transitional packages create cycles (e.g. coq → rocq-stdlib
# → rocq-core → coq). We detect and break them by removing back-edges.
##############################################################################

echo "Checking for dependency cycles..."

{
  _changed=1
  while [[ $_changed -eq 1 ]]; do
    _changed=0
    for _name in "${PKG_LIST[@]}"; do
      _deps="${PKG_DEPS[$_name]:-}"
      for _dep in $_deps; do
        _dep_deps="${PKG_DEPS[$_dep]:-}"
        for _dd in $_dep_deps; do
          if [[ "$_dd" == "$_name" ]]; then
            echo "  Breaking cycle: $_name → $_dep → $_name (removing $_dep → $_name)"
            PKG_DEPS["$_dep"]=$(echo "${PKG_DEPS[$_dep]}" | tr ' ' '\n' | { grep -v "^${_name}$" || true; } | tr '\n' ' ' | sed 's/ *$//')
            _changed=1
          fi
        done
      done
    done
  done
}

##############################################################################
# Step 5: Generate workflow YAML
##############################################################################

# Determine output file
SAFE_VERSION=$(echo "$VERSION_POSTFIX" | tr '~' '-' | tr '.' '-')
OUTPUT_DIR=".github/workflows"
OUTPUT_FILE="${OUTPUT_DIR}/opam-ci${SAFE_VERSION}.yml"

mkdir -p "$OUTPUT_DIR"

echo "Generating workflow: $OUTPUT_FILE"

# Extract a short display version from the postfix (e.g. "9.0" from "~9.0~2025.08")
DISPLAY_VERSION=$(echo "$VERSION_POSTFIX" | sed 's/^~//; s/~.*$//')

{
  cat <<HEADER
# Auto-generated by generate-workflow.sh — do not edit manually
name: "Rocq Platform CI (opam) - ${DISPLAY_VERSION}"

on:
  push:
  pull_request:
  workflow_dispatch:

env:
  OCAML_VERSION: "${OCAML_VERSION}"

HEADER

  echo "jobs:"

  for name in "${PKG_LIST[@]}"; do
    # Skip excluded packages
    is_excluded "$name" && continue

    version="${PKG_VERSION[$name]}"
    jid=$(job_id "$name")
    deps="${PKG_DEPS[$name]:-}"

    # Build the needs list — only include non-excluded deps
    needs_list=()
    for dep in $deps; do
      is_excluded "$dep" && continue
      needs_list+=("$(job_id "$dep")")
    done

    # Build cache restore keys from direct dependencies
    restore_keys=()
    for dep in $deps; do
      is_excluded "$dep" && continue
      restore_keys+=("opam-\${{ runner.os }}-$(job_id "$dep")-\${{ github.sha }}")
    done

    echo ""
    echo "  ${jid}:"

    if [[ ${#needs_list[@]} -gt 0 ]]; then
      needs_str=$(printf ', %s' "${needs_list[@]}")
      needs_str="${needs_str:2}"  # remove leading ", "
      echo "    needs: [${needs_str}]"
    fi

    cat <<JOB
    runs-on: ubuntu-latest
    steps:
      - uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: ${OCAML_VERSION}
          opam-repositories: |
            coq-core-dev: https://coq.inria.fr/opam/core-dev
            coq-extra-dev: https://coq.inria.fr/opam/extra-dev
            coq-released: https://coq.inria.fr/opam/released
            archive: git+https://github.com/ocaml/opam-repository-archive
            default: https://opam.ocaml.org
JOB

    # Restore caches from dependencies
    if [[ ${#restore_keys[@]} -gt 0 ]]; then
      for rk in "${restore_keys[@]}"; do
        cat <<RESTORE
      - uses: actions/cache/restore@v4
        with:
          path: ~/.opam
          key: ${rk}
RESTORE
      done
    fi

    cat <<INSTALL
      - run: opam install -y ${name}.${version}
        env:
          OPAMYES: "1"
      - uses: actions/cache/save@v4
        with:
          path: ~/.opam
          key: opam-\${{ runner.os }}-${jid}-\${{ github.sha }}
INSTALL
  done
} > "$OUTPUT_FILE"

echo ""
echo "Workflow generated: $OUTPUT_FILE"
echo "Jobs: $(grep -c 'runs-on:' "$OUTPUT_FILE")"
echo "Done."
