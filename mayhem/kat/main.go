// mayhem/kat/main.go — dynamically-linked known-answer probe for kubevirt's DNS
// resolv.conf parser. `import "C"` (cgo) forces a DYNAMICALLY LINKED binary so
// the gate's LD_PRELOAD sabotage shim can neuter it (a statically-linked Go
// binary would be immune, giving a false-green oracle — the trap netnew §4 warns
// about with `go test` alone).
//
// It imports the build-time-staged dns mini-module (created by mayhem/build.sh
// at _mayhem_harness/dns) and runs KATRun(), which drives fixed resolv.conf
// inputs through the REAL ParseNameservers / ParseSearchDomains /
// DomainNameWithSubdomain code, then prints each result in a fixed, greppable
// format for mayhem/test.sh to assert.
package main

// #include <stdint.h>
import "C"

import (
	"fmt"

	dns "kubevirt.local/mayhemdns"
)

func main() {
	r := dns.KATRun()
	fmt.Printf("KAT_NS4=%s\n", r.NS4)
	fmt.Printf("KAT_NS4_DEFAULT=%s\n", r.NS4Default)
	fmt.Printf("KAT_NS6_COUNT=%d\n", r.NS6Count)
	fmt.Printf("KAT_SEARCH=%s\n", r.Search)
	fmt.Printf("KAT_SEARCH_LOWER=%s\n", r.SearchLower)
	fmt.Printf("KAT_SUBDOMAIN=%s\n", r.Subdomain)
}
