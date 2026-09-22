using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "gateway", worker = (
      compatibilityDate = "2026-04-05",
      modules = [
        (name = "gateway.js", esModule = embed "gateway.js"),
        (name = "app-routing.js", esModule = embed "app-routing.js"),
        (name = "runtime-status.js", esModule = embed "runtime-status.js"),
      ],
      globalOutbound = "deny",
      bindings = [
        (name = "MANAGEMENT", service = "management"),
        (name = "ROUTER", service = "router"),
        (name = "COMPOSE", service = "compose"),
        (name = "RUNTIME_STATUS", service = "status"),
      ],
    )),
    (name = "management", worker = (
      compatibilityDate = "2026-04-05",
      modules = [
        (name = "management.js", esModule = embed "management.js"),
        (name = "runtime-status.js", esModule = embed "runtime-status.js"),
      ],
      globalOutbound = "deny",
      bindings = [
        (name = "ASSETS", service = "assets"),
        (name = "COMPOSE", service = "compose"),
        (name = "RUNTIME_STATUS", service = "status"),
      ],
    )),
    (name = "tls-gateway", worker = (
      compatibilityDate = "2026-04-05",
      compatibilityFlags = ["experimental"],
      modules = [
        (name = "tls-gateway.js", esModule = embed "tls-gateway.js"),
        (name = "tls-client-hello.js", esModule = embed "tls-client-hello.js"),
        (name = "app-routing.js", esModule = embed "app-routing.js"),
        (name = "socket-bridge.js", esModule = embed "socket-bridge.js"),
      ],
      globalOutbound = "deny",
      bindings = [
        (name = "ROUTER", service = "router"),
        (name = "COMPOSE", service = "compose"),
      ],
    )),
    (name = "router", external = (http = ())),
    (name = "assets", disk = (writable = false)),
    (name = "status", disk = (writable = false)),
    (name = "compose", external = (http = ())),
    (name = "deny", network = (allow = [])),
  ],
  sockets = [
    (name = "management", address = "127.0.0.1:8094", http = (), service = "gateway"),
    (name = "ingest", address = "127.0.0.1:80", http = (), service = "gateway"),
    (name = "tls", address = "127.0.0.1:443", tcp = (), service = "tls-gateway"),
  ],
);
