# Hosted verification performance

The target is a complete changed-source hosted loop below twenty minutes. Queue time and runner variation remain visible; a fast local run is not a hosted result. Measure the workflow from creation to completion as well as each job and verifier stage.

## Baseline

[Main run 39111471733](https://github.com/cigrainger/cadence/actions/runs/39111471733) tested `92b0f13` on macOS 15 / ARM64 with Xcode 26.3 and Swift 6.2.4. It restored a compatible compiler cache from `3744585`; changed application sources still required compilation. This was not an empty-cache build.

| Work | Time |
| --- | ---: |
| Complete hosted workflow | 25m20s |
| Verifier | 23m28s |
| Swift compile and tests stage | 7m29s |
| Swift compilation within that stage | 2m33s |
| XCTest execution within that stage | 4m50s |
| Production build stage | 6m47s |
| Native matrix, both builds | 8m08s |

The matrix executed 155 scenarios on each build. The two existing external accessibility scenarios and four live audio-output checks were explicitly skipped on CI. All 971 passing Swift tests, unit/combined coverage gates, source inventories, signatures and resource comparisons remained required. Two opt-in performance tests were skipped as documented.

## Parallel producers, one native consumer

The unit and production jobs start after repository policy passes. They use separate VMs and role-specific compiler caches. The unit job runs every test and unit coverage gate; production independently compiles and verifies the signed app. The protected `tests` job waits for both and fails if either producer failed, was cancelled or was unexpectedly skipped. It never turns a failed producer into a successful dependency skip.

The consumer runs the same complete production/instrumented native matrix, first-launch probes, device self-checks, Settings previews, signature/resource comparisons and merged coverage gates. No subset, reduced denominator, extra retry or relaxed readiness deadline was introduced. Local `./verify.sh` continues to build and test both configurations itself.

Handoffs are fresh artifacts from the current workflow run and attempt, not cached results. A SHA-256 archive digest travels through producer job outputs. Archives preserve executable permissions and reject traversal, links, duplicates and excessive sizes before extraction. A second manifest binds the exact commit/run/attempt, source and test digests, checkout path, SDK/toolchain/image fingerprint and every payload file. Both ends validate it; native coverage still hashes its copied matching objects and fresh profiles. Only selected test objects, unit evidence and the app are transferred, never the entire developer environment or cache.

Caches remain compiler work only. They retain their toolchain/path/build-flag fingerprint and GitHub branch isolation. The two producer roles can fall back to a compatible older monolithic compiler cache; neither role changes the source timestamp rule or restores profiles as results. Current-attempt transfer artifacts expire after one day, and diagnostic evidence after fourteen days. Reruns use distinct attempt names.

## Repeatable profiling

After a hosted run completes:

```sh
python3 Scripts/profile_ci.py --run RUN_ID --output .verification/profile-RUN_ID
```

This reads the workflow/job timestamps and downloads only retained diagnostic evidence. `profile.json` records queue-inclusive workflow time, job/step time, Swift compilation, actual XCTest execution and the native matrix's wall time. Overlapping scenario-pair times are not summed as elapsed time. Use a new output directory for every measurement. Source identities must agree across the evidence.

Every verifier command also writes `timings.jsonl`, including failures and elapsed subprocess time, without environment variables. Snapshot sidecars record callback-relative framing/readiness/capture phases; these do not pretend to measure process startup. Comparing them with external command time helps locate launch/exit and renderer costs.

Published before/after measurements and exact run artifacts belong in the performance pull request. Record changed-source and unchanged-source conditions separately, including cache restoration and toolchain identity. Do not use an unchanged-source cache hit as proof of the changed-source target.
