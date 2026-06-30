#!/usr/bin/env bash
set -euo pipefail

# generate-workflow-rocq-graph.sh — Generate a GitHub Actions CI workflow
# from a Rocq Platform package-pick, preserving the Rocq/Coq dependency graph.
#
# Important rule:
#   - package-pick packages are the requested targets;
#   - every transitive dependency whose name is coq, rocq, coq-* or rocq-*
#     is added as an intermediate job, even when it is not in package-pick;
#   - each job's `needs` contains its direct Rocq/Coq dependencies.

EXCLUDED_PACKAGES=(
  ocamlfind dune dune-configurator sexplib sexplib0 elpi menhir gappa eprover
  z3_tptp ott ppx_optcomp
)

die() { echo "Error: $*" >&2; exit 1; }

is_excluded() {
  local name="$1"
  for exc in "${EXCLUDED_PACKAGES[@]}"; do
    [[ "$name" == "$exc" ]] && return 0
  done
  return 1
}

job_id() {
  echo "$1" | tr '.' '-' | tr '_' '-' | tr '[:upper:]' '[:lower:]'
}

is_rocq_or_coq_pkg() {
  local name="$1"
  [[ "$name" == "coq" || "$name" == "rocq" || "$name" == coq-* || "$name" == rocq-* ]]
}

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

OCAML_VERSION=$(grep -oP 'COQ_PLATFORM_OCAML_VERSION="\K[^"]+' "$PICK_FILE" || echo "4.14.2")
VERSION_POSTFIX=$(grep -oP 'COQ_PLATFORM_PACKAGE_PICK_POSTFIX="\K[^"]+' "$PICK_FILE" || echo "unknown")

echo "OCaml version: $OCAML_VERSION"
echo "Version postfix: $VERSION_POSTFIX"
echo "Parsing package pick..."

parse_packages() {
  local file="$1"
  awk '
    BEGIN { skip = 0; extended = 0 }
    /^[[:space:]]*if false/ { skip++; next }
    skip > 0 && /^[[:space:]]*fi/ { skip--; next }
    skip > 0 { next }
    /case "\$COQ_PLATFORM_UNIMATH"/ { skip++; next }
    /case "\$COQ_PLATFORM_COMPCERT"/ { skip++; next }
    /case "\$COQ_PLATFORM_VST"/ { skip++; next }
    /case "\$COQ_PLATFORM_FIATCRYPTO"/ { skip++; next }
    skip > 0 && /esac/ { skip--; next }
    skip > 0 { next }
    /COQ_PLATFORM_EXTENT.*\^\[xX\]/ { extended = 1; next }
    extended && /^fi/ { extended = 0; next }
    extended { next }
    /PACKAGES="\$\{PACKAGES\}/ { print }
  ' "$file" \
  | grep -oP '(?<=PACKAGES="\$\{PACKAGES\} )[^"]+' \
  | tr ' ' '\n' \
  | while read -r token; do
      [[ -z "$token" ]] && continue
      [[ "$token" == PIN.* ]] && token="${token#PIN.}"
      echo "$token"
    done
}

declare -A PKG_VERSION      # package -> version, only for package-pick targets
declare -A IS_PICK_PACKAGE  # package -> 1 if it comes from package-pick
declare -A PKG_SET          # every node in graph
declare -a PKG_LIST         # ordered graph nodes

enqueue_pkg() {
  local name="$1"
  if [[ -z "${PKG_SET[$name]:-}" ]]; then
    PKG_SET["$name"]=1
    PKG_LIST+=("$name")
  fi
}

while read -r nv; do
  if [[ "$nv" =~ ^([a-zA-Z][a-zA-Z0-9_-]*)\.([0-9v].*)$ ]]; then
    name="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
  else
    echo "Warning: cannot parse '$nv', skipping" >&2
    continue
  fi
  PKG_VERSION["$name"]="$version"
  IS_PICK_PACKAGE["$name"]=1
  enqueue_pkg "$name"
done < <(parse_packages "$PICK_FILE")

echo "Found ${#PKG_LIST[@]} package-pick packages"

# Always keep known roots visible as graph nodes.
for root in coq coq-core coq-stdlib coqide-server rocq-core rocq-stdlib rocqide; do
  enqueue_pkg "$root"
done

extract_dep_names() {
  local raw_deps="$1"
  echo "$raw_deps" | grep -oP '"[a-zA-Z][a-zA-Z0-9_-]*"' | tr -d '"' | sort -u || true
}

opam_depends_raw() {
  local name="$1"
  local version="${PKG_VERSION[$name]:-}"
  local raw=""

  # Try exact package-pick version first, then package name.
  if [[ -n "$version" ]]; then
    raw=$(opam show --field=depends "${name}.${version}" 2>/dev/null || true)
  fi
  if [[ -z "$raw" ]]; then
    raw=$(opam show --field=depends "$name" 2>/dev/null || true)
  fi

  # Transitional fallback: rocq-X may be available as coq-X, or the opposite.
  if [[ -z "$raw" && "$name" == rocq-* ]]; then
    raw=$(opam show --field=depends "coq-${name#rocq-}" 2>/dev/null || true)
  elif [[ -z "$raw" && "$name" == coq-* ]]; then
    raw=$(opam show --field=depends "rocq-${name#coq-}" 2>/dev/null || true)
  fi

  printf '%s\n' "$raw"
}

declare -A PKG_DEPS # package -> direct Rocq/Coq deps

echo "Resolving transitive Rocq/Coq graph via opam show --field=depends..."
idx=0
while [[ $idx -lt ${#PKG_LIST[@]} ]]; do
  name="${PKG_LIST[$idx]}"
  idx=$((idx + 1))

  raw_deps=$(opam_depends_raw "$name")
  dep_names=()
  declare -A seen=()

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    is_rocq_or_coq_pkg "$dep" || continue
    [[ "$dep" == "$name" ]] && continue
    [[ -n "${seen[$dep]:-}" ]] && continue

    seen["$dep"]=1
    dep_names+=("$dep")
    enqueue_pkg "$dep"
  done < <(extract_dep_names "$raw_deps")

  unset seen
  PKG_DEPS["$name"]="${dep_names[*]:-}"

  if [[ -n "${dep_names[*]:-}" ]]; then
    echo "  $name -> ${dep_names[*]}"
  else
    echo "  $name -> (no direct Rocq/Coq deps found)"
  fi

done

SAFE_VERSION=$(echo "$VERSION_POSTFIX" | tr '~' '-' | tr '.' '-')
OUTPUT_DIR=".github/workflows"
OUTPUT_FILE="${OUTPUT_DIR}/opam-ci${SAFE_VERSION}.yml"
DEBUG_FILE="${OUTPUT_DIR}/opam-ci${SAFE_VERSION}.graph.txt"
mkdir -p "$OUTPUT_DIR"
DISPLAY_VERSION=$(echo "$VERSION_POSTFIX" | sed 's/^~//; s/~.*$//')

echo "Writing graph debug file: $DEBUG_FILE"
{
  echo "# Direct Rocq/Coq dependency graph generated from opam show --field=depends"
  echo "# Format: package: dep1 dep2 ..."
  for name in "${PKG_LIST[@]}"; do
    is_excluded "$name" && continue
    echo "$name: ${PKG_DEPS[$name]:-}"
  done
} > "$DEBUG_FILE"

echo "Generating workflow: $OUTPUT_FILE"
{
  cat <<HEADER
# Auto-generated by generate-workflow-rocq-graph.sh — do not edit manually
name: "Rocq Platform CI (opam) - ${DISPLAY_VERSION}"

on:
  push:
  pull_request:
  workflow_dispatch:

env:
  OCAML_VERSION: "${OCAML_VERSION}"

jobs:
HEADER

  for name in "${PKG_LIST[@]}"; do
    is_excluded "$name" && continue

    jid=$(job_id "$name")
    version="${PKG_VERSION[$name]:-}"
    deps="${PKG_DEPS[$name]:-}"

    if [[ -n "$version" ]]; then
      install_target="${name}.${version}"
    else
      install_target="$name"
    fi

    needs_list=()
    restore_keys=()
    for dep in $deps; do
      is_excluded "$dep" && continue
      needs_list+=("$(job_id "$dep")")
      restore_keys+=("opam-\${{ runner.os }}-$(job_id "$dep")-\${{ github.sha }}")
    done

    echo ""
    echo "  ${jid}:"
    if [[ ${#needs_list[@]} -gt 0 ]]; then
      needs_str=$(printf ', %s' "${needs_list[@]}")
      echo "    needs: [${needs_str:2}]"
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

    for rk in "${restore_keys[@]}"; do
      cat <<RESTORE
      - uses: actions/cache/restore@v4
        with:
          path: ~/.opam
          key: ${rk}
RESTORE
    done

    cat <<INSTALL
      - run: opam install -y ${install_target}
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
echo "Graph debug generated: $DEBUG_FILE"
echo "Jobs: $(grep -c 'runs-on:' "$OUTPUT_FILE")"
echo "Check mathcomp with: grep -E 'rocq-mathcomp-ssreflect|rocq-mathcomp-boot' '$DEBUG_FILE' '$OUTPUT_FILE'"
echo "Done."