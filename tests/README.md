# tests

Mocked-UCI / state-machine / package tests (host-runnable, no hardware). Port the useful
vendor test ideas with generic `radio0`/`radio1` fixtures:

- travelmate defaults: idempotency, AP preservation, exactly one STA, band discovery, no creds
- mwan3 policy: member ordering, no hard-coded `eth2`, tailscale0 excluded
- egress selector: all six transitions, invalid state, rollback, mark disjointness
