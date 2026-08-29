#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for kubevirt's DNS resolv.conf parser.
# Runs the dynamically-linked KAT probe (/mayhem/kubevirt_dns_kat, built by
# build.sh) that drives fixed resolv.conf inputs through the REAL
# ParseNameservers / ParseSearchDomains / DomainNameWithSubdomain code and
# asserts EXACT behavioral values, every one lifted from kubevirt's own
# pkg/network/dns/resolveconf_test.go:
#   - "nameserver 8.8.8.8 / 8.8.4.4"                -> IPv4 == 8.8.8.8,8.8.4.4
#   - ""                                            -> IPv4 defaults to 8.8.8.8
#   - "nameserver 2001:db8::1 / ::1"                -> 2 IPv6 nameservers
#   - "search cluster.local svc.cluster.local example.com" -> those 3 domains
#   - "search LoCaL"                                -> local  (lower-cased)
#   - DomainNameWithSubdomain(..., "subdomain")     -> subdomain.default.svc.cluster.local
#
# Why not `go test` alone (netnew §4): a Go test binary is statically linked, so
# the gate's LD_PRELOAD sabotage shim cannot neuter it — the suite would survive
# sabotage while proving nothing (the cosign/notary false-green). The KAT probe
# is cgo-linked (dynamic), so when the program is neutered to _exit(0) it prints
# nothing, every assertion below misses, and test.sh FAILS — which is the point.
#
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PROBE=/mayhem/kubevirt_dns_kat
passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
if [ ! -x "$PROBE" ]; then
  echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "kubevirt-dns-kat" 0 1
  exit 1
fi

OUT="$("$PROBE" 2>/dev/null)"
echo "--- KAT probe output ---"; printf '%s\n' "$OUT"; echo "------------------------"

# Exact-line assertions (grep -qxF: whole-line, fixed-string).
assert_line() { # <desc> <expected-exact-line>
  if printf '%s\n' "$OUT" | grep -qxF "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected exact line: $2)"; failed=$((failed+1))
  fi
}

assert_line "two IPv4 nameservers parse in order"          "KAT_NS4=8.8.8.8,8.8.4.4"
assert_line "empty resolv.conf defaults to 8.8.8.8"        "KAT_NS4_DEFAULT=8.8.8.8"
assert_line "two IPv6 nameservers parse"                   "KAT_NS6_COUNT=2"
assert_line "three search domains parse in order"          "KAT_SEARCH=cluster.local,svc.cluster.local,example.com"
assert_line "mixed-case search domain lower-cased"         "KAT_SEARCH_LOWER=local"
assert_line "subdomain prepended to longest service domain" "KAT_SUBDOMAIN=subdomain.default.svc.cluster.local"

emit_ctrf "kubevirt-dns-kat" "$passed" "$failed"
