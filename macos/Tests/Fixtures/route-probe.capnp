using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [(name = "files", disk = (path = "/www", writable = false))],
  sockets = [(name = "http", address = "0.0.0.0:8080", http = (), service = "files")],
);
