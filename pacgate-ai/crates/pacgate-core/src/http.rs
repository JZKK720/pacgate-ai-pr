//! HTTP client construction for services that may be LOCAL.
//!
//! ## The defect this module exists for
//!
//! `reqwest` 0.12 reads the *operating system* proxy when no `*_PROXY`
//! environment variable is set. On Windows that is the WinINET entry
//! (`HKCU\...\Internet Settings\ProxyServer`, typically a local SOCKS/HTTP
//! client such as `127.0.0.1:7890`). Nothing in that path excludes loopback,
//! and this fleet ships with `NO_PROXY` UNSET, so:
//!
//! ```text
//! pacgate-api --POST--> http://host.docker.internal:11434  (Ollama)
//! pacgate-api --POST--> http://ocr-service:8100            (OCR)
//! pacgate-api --POST--> http://localhost:11434             (embeddings)
//! pacgate-llm --POST--> http://127.0.0.1:PORT              (any local model)
//! ```
//!
//! is routed to `127.0.0.1:7890` instead of to the local service. The proxy
//! cannot resolve those names, so it answers `502 Bad Gateway`. Measured
//! 2026-11-04 on this workstation: 6 of 12 `pacgate-agent` tests failed with
//! `LlmError("... error=HTTP status server error (502 Bad Gateway) for url
//! (http://127.0.0.1:58234/v1/chat/completions)")` and the same suite passed
//! 12/12 the moment `NO_PROXY=127.0.0.1,localhost` was exported.
//!
//! That is why the user's symptom was "the agent spins for 36 steps and never
//! answers": every model call in the turn went through a proxy that had no route
//! to the GPU, so the turn only advanced when the retry budget ran out.
//!
//! ## The rule
//!
//! A client that talks to a local service must be built here. Do NOT call
//! `reqwest::Client::new()` (or `Client::builder()`) for Ollama, the OCR
//! service, or any `localhost` / `*.local` / `host.docker.internal` endpoint -
//! those constructors inherit the machine proxy and will work on the developer
//! machine that set `NO_PROXY` and fail on a client AIPC that did not.
//!
//! Clients that call genuine remote APIs (Anthropic, OpenAI, the legal data
//! sources) are unaffected and may keep the default behaviour.

use std::time::Duration;

/// Host names and address ranges that must never be proxied.
///
/// `host.docker.internal` is how a container reaches the AIPC's native Ollama,
/// so it is local in effect even though it is a DNS name.
const LOCAL_BYPASS: &str = "localhost,127.0.0.1,127.0.0.0/8,::1,[::1],\
                            *.local,host.docker.internal";

/// Build an HTTP client that is safe to point at a local service.
///
/// A machine-wide `HTTP(S)_PROXY` is a legitimate egress path for cloud model
/// providers, so it is honoured - but only after local destinations have been
/// exempted explicitly. `timeout` is a total-request ceiling, which is what
/// converts an indefinite hang into a diagnosable error.
pub fn local_service_client(timeout: Option<Duration>) -> reqwest::Client {
    // `no_proxy()` clears every proxy reqwest auto-derived from the platform,
    // including the WinINET one that has no bypass list. Without it, `.proxy()`
    // below would merely ADD to the inherited list rather than replace it.
    let mut builder = reqwest::Client::builder().no_proxy();

    if let Some(proxy) = explicit_proxy_from_env() {
        builder = builder.proxy(proxy.no_proxy(reqwest::NoProxy::from_string(LOCAL_BYPASS)));
    }

    if let Some(timeout) = timeout {
        builder = builder.timeout(timeout);
    }

    builder.build().expect("static HTTP client configuration")
}

/// Resolve an explicitly configured proxy, if any.
///
/// Only environment variables are consulted. The platform proxy is deliberately
/// NOT read here: it cannot be exempted before it is applied, and a proxy the
/// user did not configure should not be used to reach a local service.
fn explicit_proxy_from_env() -> Option<reqwest::Proxy> {
    // HTTPS_PROXY first: it is the more specific setting, and matching reqwest's
    // own precedence keeps behaviour predictable for operators.
    for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] {
        let Ok(value) = std::env::var(key) else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        match reqwest::Proxy::all(value) {
            Ok(proxy) => return Some(proxy),
            // A malformed proxy value must not silently disable the proxy: the
            // caller asked for egress, so the build fails rather than quietly
            // going direct. reqwest reports this at request time otherwise.
            Err(err) => panic!("invalid proxy in {key}={value:?}: {err}"),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// Environment variables are process-global, so the proxy tests must not run
    /// concurrently. A `tokio` mutex is used rather than a `std` one because the
    /// guard IS held across `await` - that is the whole point of the test.
    static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// A loopback server that answers any request with 200 and an empty body.
    fn spawn_ok_server() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { break };
                let mut buf = vec![0u8; 8192];
                let _ = stream.read(&mut buf);
                let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                let _ = stream.flush();
            }
        });
        format!("http://127.0.0.1:{port}")
    }

    /// The regression: a loopback request must reach the loopback server even
    /// when the process is configured with an HTTP proxy that cannot serve it.
    ///
    /// Before `local_service_client` existed, `Client::new()` inherited that
    /// proxy, so this request went to the dead port and the call failed - the
    /// exact `502 Bad Gateway` the agent loop surfaced to the user.
    #[tokio::test]
    async fn local_service_client_reaches_loopback_while_a_proxy_is_configured() {
        let _guard = ENV_LOCK.lock().await;
        let base = spawn_ok_server();

        // A port nothing listens on: any request routed here fails immediately,
        // so a pass proves the request went DIRECT.
        let dead = TcpListener::bind("127.0.0.1:0").unwrap();
        let dead_url = format!("http://{}", dead.local_addr().unwrap());
        drop(dead);

        // SAFETY: guarded by ENV_LOCK; restored before the guard is released.
        std::env::set_var("HTTP_PROXY", &dead_url);
        std::env::set_var("http_proxy", &dead_url);

        let result = local_service_client(Some(Duration::from_secs(5)))
            .post(format!("{base}/v1/chat/completions"))
            .send()
            .await;

        std::env::remove_var("HTTP_PROXY");
        std::env::remove_var("http_proxy");

        let response = result.expect(
            "a loopback call must not be sent to the configured proxy - if this fails, \
             the client inherited the machine proxy and every local Ollama/OCR call \
             will 502 on a client machine",
        );
        assert_eq!(response.status(), 200);
    }

    /// The control: the same configuration and the same code path, but with the
    /// default constructor. Pinned so the defect cannot be re-introduced silently
    /// - if reqwest ever stops honouring the proxy here, this test tells us the
    /// guard in `local_service_client` is no longer load-bearing.
    #[tokio::test]
    async fn a_default_client_would_take_the_proxy_and_fail() {
        let _guard = ENV_LOCK.lock().await;
        let base = spawn_ok_server();

        let dead = TcpListener::bind("127.0.0.1:0").unwrap();
        let dead_url = format!("http://{}", dead.local_addr().unwrap());
        drop(dead);

        std::env::set_var("HTTP_PROXY", &dead_url);
        std::env::set_var("http_proxy", &dead_url);

        let result = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap()
            .post(format!("{base}/v1/chat/completions"))
            .send()
            .await;

        std::env::remove_var("HTTP_PROXY");
        std::env::remove_var("http_proxy");

        assert!(
            result.is_err(),
            "expected the default client to fail against a dead proxy; if this now \
             succeeds, reqwest changed its proxy behaviour and the local_service_client \
             guard should be re-evaluated rather than kept on faith"
        );
    }

    /// An explicit proxy must still be honoured, so the helper does not disable
    /// operator-configured egress for the remote model providers.
    #[tokio::test]
    async fn an_explicit_proxy_from_env_is_still_honoured() {
        let _guard = ENV_LOCK.lock().await;
        std::env::set_var("HTTPS_PROXY", "http://proxy.example:3128");
        std::env::remove_var("http_proxy");

        let proxy = explicit_proxy_from_env();

        std::env::remove_var("HTTPS_PROXY");

        assert!(
            proxy.is_some(),
            "a configured HTTPS_PROXY must still be used for remote destinations"
        );
    }

    /// With no proxy configured the helper must still produce a usable client.
    #[tokio::test]
    async fn no_proxy_configured_yields_a_client() {
        let _guard = ENV_LOCK.lock().await;
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] {
            std::env::remove_var(key);
        }
        assert!(explicit_proxy_from_env().is_none());
        let _client = local_service_client(None);
    }
}
