{:ok, _pid} = AvroSchema.start_link(cache_dir: "/tmp")
ExUnit.start()
ExUnit.configure(exclude: [
  :skip,
  :live_registry,
])
