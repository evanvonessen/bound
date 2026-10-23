The compile-time declarations in `nakama-runtime.d.ts` come from
`heroiclabs/nakama-common`, commit `189a8ea03d9038126437666745a9d5f74ee21c30`,
`index.d.ts`. They are licensed under Apache-2.0; see `LICENSE`.

Source: https://github.com/heroiclabs/nakama-common/blob/189a8ea03d9038126437666745a9d5f74ee21c30/index.d.ts

These declarations are not included in the executable runtime bundle.

`nakama-3.41-compat.d.ts` is a separate local declaration for two verified runtime
hooks missing or misnamed in these upstream types. Nakama 3.41.0 exposes
`registerBeforeAuthenticate` and `registerBeforeSessionRefresh` in
`server/runtime_javascript_init.go`; the runtime is tested against that binary.
