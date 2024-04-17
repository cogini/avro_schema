ExUnit.configure(
  formatters: [JUnitFormatter, ExUnit.CLIFormatter],
  exclude: [
    :skip,
    :live_registry
  ]
)

{:ok, _pid} = AvroSchema.start_link(cache_dir: "/tmp")
ExUnit.start()
