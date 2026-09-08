using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "gateway", worker = (
      compatibilityDate = "2026-04-05",
      modules = [
        (name = "gateway.js", esModule = embed "gateway.js"),
        (name = "app-routing.js", esModule = embed "app-routing.js"),
      ],
      globalOutbound = "deny",
      bindings = [
        (name = "MANAGEMENT", service = "management"),
        (name = "ROUTER", service = "router"),
        (name = "COMPOSE", service = "compose"),
      ],
    )),
    (name = "management", worker = (
      compatibilityDate = "2026-04-05",
      modules = [(name = "management.js", esModule = embed "management.js")],
      globalOutbound = "deny",
      bindings = [(name = "ASSETS", service = "assets"), (name = "COMPOSE", service = "compose")],
    )),
    (name = "router", external = (http = ())),
    (name = "assets", disk = (writable = false)),
    (name = "compose", external = (http = ())),
    (name = "deny", network = (allow = [])),
  ],
  sockets = [
    (name = "management", address = "127.0.0.1:8094", http = (), service = "gateway"),
    (name = "ingest", address = "127.0.0.1:5196", http = (), service = "gateway"),
  ],
);
