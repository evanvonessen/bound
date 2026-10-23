// The pinned upstream declarations call the provider hook
// registerBeforeAuthenticateProvider and omit session-refresh hooks. Nakama
// 3.41.0's actual runtime_javascript_init.go exposes these names instead.
// Keep the upstream file byte-for-byte intact and describe the tested surface.
declare namespace nkruntime {
    interface Initializer {
        registerBeforeAuthenticate(fn: BeforeHookFunction<AuthenticateProviderRequest>): void;
        registerBeforeSessionRefresh(fn: BeforeHookFunction<any>): void;
    }
}
