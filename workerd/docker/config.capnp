using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "router", worker = (
      compatibilityDate = "2026-04-05",
      modules = [(name = "router.js", esModule = embed "../router.js")],
      globalOutbound = "containers",
      bindings = [(name = "DOCKER", service = "docker")],
    )),
    (name = "docker", external = (address = "unix:/var/run/docker.sock", http = ())),
    (name = "containers", network = (allow = ["private", "127.0.0.1/32"])),
  ],
  sockets = [(name = "router", address = "unix:/run/xe-router/workerd.sock", http = (), service = "router")],
);
