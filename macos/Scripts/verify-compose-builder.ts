const info = JSON.parse(await new Response(Deno.stdin.readable).text());
if (info.builder !== "buildkit") {
  throw new Error("Compose asset still supports classic builds; build the updated source or update the release pin");
}
