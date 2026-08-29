#!/usr/bin/env bash
#
# mayhem/build.sh — build kubevirt's DNS resolv.conf parser
# (pkg/network/dns/resolveconf.go) as a sanitized libFuzzer binary (OSS-Fuzz Go
# path: go-118-fuzz-build -libfuzzer archive + clang++ ASan link), plus a
# dynamically-linked KAT oracle probe for mayhem/test.sh to run.
#
# Runs inside the commit image (Go mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV under /opt/toolchains
# (absolute, $HOME-independent — so the offline PATCH re-run finds the cache).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) fills $GOMODCACHE (go get of the /testing shim).
#   - GOPROXY points at the in-image module cache's file proxy FIRST, network
#     LAST, so the offline re-run resolves entirely from the cache; GOFLAGS=-mod=mod
#     + GOSUMDB=off keep go.sum verification local (no sum.golang.org round trip).
#
# HARNESS STAGING (netnew §6 Go / port-go — the giant-Go mini-module pattern):
# kubevirt's real module is `module kubevirt.io/kubevirt; go 1.26.0` and drags the
# entire Kubernetes closure (client-go, api-machinery, controller-runtime,
# libvirt bindings, cni…) through go.mod. pkg/network/dns/resolveconf.go's
# ParseNameservers / ParseSearchDomains / domain helpers need only stdlib + ONE
# symbol group (Log.Warningf / Log.Infof) from kubevirt.io/client-go/log. So we
# copy JUST resolveconf.go into a fresh STANDALONE Go mini-module at
# _mayhem_harness/dns, repoint its one non-stdlib import at a tiny local `log`
# shim (the crossplane trick — same package name, so every log.Log.* call site is
# untouched), and build there. The module's only downloaded dep is the
# go-118-fuzz-build /testing shim (which transitively provides go-fuzz-headers) —
# kubevirt's giant graph is never touched. The staging dir is leading-underscore
# so `go build/test ./...` wildcards skip it and it can never disturb upstream.
set -euo pipefail

: "${SRC:=/mayhem}"

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# Sanitizers (§6.1): the OSS-Fuzz Go path is ASan-only for the libFuzzer link.
# Honor the knob — an explicit empty SANITIZER_FLAGS yields an un-sanitized build.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export SANITIZER_FLAGS
GO_SAN="-fsanitize=address"
[ -n "${SANITIZER_FLAGS}" ] || GO_SAN=""

# Debug-info contract (§6.2 item 10): gc always emits DWARF4 with no knob, so we
# force the clang-compiled cgo C shims to DWARF3 (CGO_CFLAGS/CGO_CXXFLAGS) AND
# prepend a DWARF3 anchor.o at the final clang++ link so the FIRST .debug_info CU
# (what the gate reads) is DWARF < 4. $GO_DEBUG_FLAGS threads any base pins.
export GO_DEBUG_FLAGS="${GO_DEBUG_FLAGS:--gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} ${GO_DEBUG_FLAGS}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} ${GO_DEBUG_FLAGS}"

# kubevirt ships a repo-root go.work (multi-module workspace). The staged
# mini-module lives UNDER /mayhem, so go would otherwise pick up that workspace
# and reject -mod=mod ("-mod may only be set to readonly/vendor in workspace
# mode"). Disable workspace mode so the mini-module resolves standalone from its
# own go.mod — crossplane had no go.work and so did not need this.
export GOWORK=off

# Resolve modules offline-first from the in-image cache; network only as fallback.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOSUMDB="${GOSUMDB:-off}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

go version

TARGET="fuzz_dns"
STAGE="$SRC/_mayhem_harness/dns"
MODPATH="kubevirt.local/mayhemdns"

# Pseudo-version of the go-118-fuzz-build /testing shim that the Dockerfile's
# `go install ...@a70c2aa677fa...` already resolved + cached. A raw commit hash
# forces a proxy.golang.org round trip to resolve it — fatal on the air-gapped
# PATCH re-run; the pseudo-version resolves straight from the file cache.
GO118_SHIM_VERSION="v0.0.0-20250520111509-a70c2aa677fa"

# ── Stage a standalone mini-module: resolveconf.go (verbatim) + shim + harness + KAT ─
rm -rf "$STAGE"
mkdir -p "$STAGE/log" "$STAGE/kat"

# resolveconf.go copied verbatim; repoint ONLY its kubevirt.io/client-go/log
# import at the local shim (same package name `log`, so log.Log.Warningf/Infof
# call sites are untouched).
sed 's#kubevirt.io/client-go/log#'"$MODPATH"'/log#' \
  "$SRC/pkg/network/dns/resolveconf.go" > "$STAGE/resolveconf.go"
grep -q "$MODPATH/log" "$STAGE/resolveconf.go" \
  || { echo "FATAL: client-go/log import rewrite failed in staged resolveconf.go"; exit 1; }

cp "$SRC/mayhem/log_shim.go.src"               "$STAGE/log/log.go"
cp "$SRC/mayhem/harness_resolveconf.go.src"    "$STAGE/harness_resolveconf.go"
cp "$SRC/mayhem/kat_export.go.src"             "$STAGE/kat_export.go"
cp "$SRC/mayhem/kat/main.go"                   "$STAGE/kat/main.go"

# ── Module graph: init, add the /testing shim, then tidy ───────────────────────
(
  cd "$STAGE"
  go mod init "$MODPATH"
  # The /testing shim pulls go-fuzz-headers transitively; both resolve from the
  # file-proxy cache offline on the PATCH re-run.
  go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_SHIM_VERSION}"
  go mod tidy
)

# ── Build the libFuzzer archive from the staged mini-module ────────────────────
mkdir -p "$SRC/mayhem-build"
echo "=== go-118-fuzz-build $TARGET (func FuzzResolveConf) ==="
(
  cd "$STAGE"
  go-118-fuzz-build -func FuzzResolveConf -o "$SRC/mayhem-build/$TARGET.a" .
)

# ── DWARF3 anchor FIRST, then clang++ ASan+fuzzer link ─────────────────────────
printf 'int __mayhem_dwarf3_anchor;\n' > "$SRC/mayhem-build/anchor.c"
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem-build/anchor.c" -o "$SRC/mayhem-build/anchor.o"
$CXX $GO_SAN $LIB_FUZZING_ENGINE \
     "$SRC/mayhem-build/anchor.o" "$SRC/mayhem-build/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# ── KAT oracle probe: dynamically-linked (cgo) so the sabotage shim can neuter it ─
export CGO_ENABLED=1
(
  cd "$STAGE"
  go build -o /mayhem/kubevirt_dns_kat ./kat
)
file /mayhem/kubevirt_dns_kat | grep -q 'dynamically linked' \
  || { echo "FATAL: /mayhem/kubevirt_dns_kat is not dynamically linked — oracle would be reward-hackable"; exit 1; }
echo "built /mayhem/kubevirt_dns_kat (dynamically linked)"

echo "build.sh complete"
