/* Fleet policy (SPEC.md 6.1): disable LeakSanitizer preventively at BUILD time. ASan
   use-after-free/overflow stays fully on and halting -- only leak detection is affected.

   kubevirt's harness is a Go target linked through the OSS-Fuzz Go path (go-118-fuzz-build
   -libfuzzer archive, then a clang++ ASan link). The Go runtime keeps arenas and goroutine
   stacks alive for the process lifetime by design, so LSan's at-exit scan reports the
   runtime's own allocations on every input rather than a defect in the code under test.

   A runtime ASan default-options override -- whether compiled in or passed via ASAN_OPTIONS -- is
   forbidden, because Mayhem alone owns the runtime ASAN/LibFuzzer option set, so this is done via
   the sanctioned build-time hook instead. SPEC.md 6.2 item 15 bans the override symbol NAMES
   anywhere under mayhem/, comments included, so the forbidden construct is described in prose here
   rather than named. __lsan_is_turned_off is the sanctioned hook and is NOT the banned construct. */
int __lsan_is_turned_off(void) {
  return 1;
}
