defmodule AvroSchema do
  @moduledoc """
  Encode and decode [Avro](https://avro.apache.org/) data with schema tags.
  """
  @app :avro_codec

  @type regid() :: pos_integer()
  @type name() :: binary()
  #   @type fp() :: :avro.crc64_fingerprint() | binary()
  @type fp() :: binary()
  @type ref() :: regid() | {name(), fp()}
  @type client() :: :tesla.client()

  @dets_table @app
  @ets_table __MODULE__

  use GenServer

  require Logger

  # Public API

  @doc """
  Tag Avro binary data with schema.

  Uses [Confluent wire format](https://docs.confluent.io/current/schema-registry/serializer-formatter.html#wire-format)
  for integer registry IDs and [Avro single object encoding](https://avro.apache.org/docs/1.8.2/spec.html#single_object_encoding_spec)
  for fingerprints.

  This function matches schema IDs as integers and fingerprints as binary.
  Strictly speaking, though fingerprints can be integers, so make sure that you
  convert them to binary first.
  """
  @spec tag(binary, regid | fp) :: iolist
  def tag_bin(bin, fp) when is_binary(fp) do
    [<<0xC3, 0x01, fp::unsigned-little-64>>, bin]
  end
  def tag(bin, regid) when is_integer(regid) do
    [<<0, regid::unsigned-big-32>>, bin]
  end

  @doc """
  Split schema tag from tagged Avro binary data.

  Supports [Confluent wire format](https://docs.confluent.io/current/schema-registry/serializer-formatter.html#wire-format)
  for integer registry IDs and [Avro single object encoding](https://avro.apache.org/docs/1.8.2/spec.html#single_object_encoding_spec)
  for fingerprints.
  """
  @spec untag(binary) ::
    {:ok, {regid, binary}} | {:ok, {{:avro, binary}, binary}} | {:error, :unknown_tag}
  def untag(<<0, regid::unsigned-big-32, data::binary>>) do
    {:ok, {{:confluent, regid}, data}}
  end
  def untag(<<0xC3, 0x01, fp::bytes-size(8), data::binary>>) do
    {:ok, {{:avro, fp}, data}}
  end
  def untag(_) do
    {:error, :unknown_tag}
  end

  @doc """
  Get schema and codecs for schema reference.

  This call has the overhead of an ETS lookup and potentially a GenServer call
  to fetch the Avro schema via HTTP. If you need maximum performance, keep the
  result and reuse it for future requests with the same reference.
  """
  @spec get_schema(ref) :: {:ok, map} | {:error, term}
  def get_schema(ref) do
    case cache_lookup(ref) do
      nil ->
        GenServer.call(__MODULE__, {:get_schema, ref})
      value ->
        {:ok, value}
    end
  end

  @doc """
  Register schema with subject in Confluent Schema Registry.

  It is safe to register the same schema multiple times, it will always return
  the same ID.
  """
  @spec register_schema(binary, binary) :: {:ok, regid} | {:error, term}
  def register_schema(subject, schema) when is_binary(schema) do
    case cache_lookup({subject, schema}) do
      nil ->
        GenServer.call(__MODULE__, {:register_schema, subject, schema})
      value ->
        {:ok, value}
    end
  end

  @spec encode_schema(:avro.type) :: binary
  def encode_schema(schema) do
    :avro.encode_schema(schema)
  end

  @spec get_decoder(regid) :: {:ok, fun} | {:error, term}
  def get_decoder(regid) when is_integer(regid) do
    with {:ok, schema} <- get_schema(regid),
         {:ok, schema} = parse_schema(schema),
         decoder = :avro.make_simple_decoder(schema, [])
    do
      {:ok, decoder}
    else
      error -> error
    end
  end
  def get_decoder({:confluent, regid}), do: get_decoder(regid)

  @doc "Make Avro decoder for schema"
  @spec make_encoder(binary | :avro.type) :: {:ok, fun} | {:error, term}
  def make_decoder(schema_json) when is_binary(schema_json) do
    case parse_schema(schema_json) do
      {:ok, schema} ->
        {:ok, :avro.make_simple_decoder(schema, [])}
      error -> error
    end
  end
  def make_decoder(schema) do
    {:ok, :avro.make_simple_decoder(schema, [])}
  end

  @doc "Make Avro encoder for schema"
  @spec make_encoder(binary | :avro.type) :: {:ok, fun} | {:error, term}
  def make_encoder(schema_json) when is_binary(schema_json) do
    case parse_schema(schema_json) do
      {:ok, schema} ->
        {:ok, :avro.make_simple_encoder(schema, [])}
      error ->
        error
    end
  end
  def make_encoder(schema) do
    {:ok, :avro.make_simple_encoder(schema, [])}
  end

  @spec decode(binary) :: [{binary, term}]
  def decode(tagged_bin) do
    with {:ok, {reg, data}} <- untag(tagged_bin),
         {:ok, %{decoder: decoder}} <- get_schema(reg)
    do
      {:ok, decoder.(data)}
    else
      error -> error
    end
  end

  @spec decode(binary, fun) :: [{binary, term}]
  def decode(bin, decoder) do
    decoder.(bin)
  end

  @spec encode([{binary, term}], fun) :: binary
  def encode(data, encoder) do
    encoder.(data)
  end

  @doc """
  Create fingerprint of schema JSON.

  Ensures that schema is in standard form, then generates an
  CRC-64-AVRO fingerprint on it.
  """
  @spec fingerprint_schema(binary) :: binary
  def fingerprint_schema(schema) do
    schema
    |> canonicalize_schema()
    |> normalize_json()
    |> create_fingerprint()
  end

  @doc """
  Ensure Avro schema is in Parsing Canonical Form.

  Converts schema into [Parsing Canonical Form](https://avro.apache.org/docs/current/spec.html#Parsing+Canonical+Form+for+Schemas)
  by decoding it and re-encoding it.
  """
  @spec canonicalize_schema(binary) :: binary
  def canonicalize_schema(schema) when is_binary(schema) do
    schema = :avro.decode_schema(schema)
    :avro.encode_schema(schema, canon: true)
  end

  @doc """
  Normalize JSON by decoding and re-encoding it. This reduces irrelevant
  differences such as whitespace which may affect fingerprinting.
  """
  @spec normalize_json(binary) :: binary
  def normalize_json(json) do
    parsed_json = :jsone.decode(json, object_format: :tuple)
    :jsone.encode(parsed_json)
  end

  @doc """
  Create CRC-64-AVRO fingerprint hash for Avro schema JSON.

  See [CRC-64-AVRO](https://avro.apache.org/docs/1.8.2/spec.html#schema_fingerprints)
  """
  @spec create_fingerprint(binary) :: binary
  def create_fingerprint(schema) do
    <<:avro.crc64_fingerprint(schema) :: little-size(64)>>
  end

  @doc "Make registration subject from name + fingerprint."
  @spec make_subject({binary, binary}) :: binary
  def make_subject({name, fp}) when is_binary(fp) do
    fp_hex = Base.encode16(fp, case: :lower)
    "#{name}-#{fp_hex}"
  end

  @doc "Make registration subject from name + fingerprint."
  @spec make_subject(binary, binary) :: binary
  def make_subject(name, fp) when is_binary(fp), do: make_subject({name, fp})

  # TODO: is_registered?

  @doc "Parse schema into avro library internal form"
  @spec parse_schema(binary) :: {:ok, :avro.avro_type()} | {:error, term}
  def parse_schema(json) do
    avro_type = :avro.decode_schema(json)
    lkup = :avro.make_lkup_fun(avro_type)
    {:ok, :avro.expand_type_bloated(avro_type, lkup)}
  rescue
    e in RuntimeError -> {:error, {:parse_schema, e}}
    # e in ArgumentError -> {:error, e.message}
    # e in ErlangError -> {:error, e.original}
  end

  @doc "Convert DateTime to Avro integer timestamp"
  @spec to_timestamp(DateTime.t) :: non_neg_integer
  def to_timestamp(date_time) do
    DateTime.to_unix(date_time, :microsecond)
  end

  @spec full_name(tuple) :: binary
  def full_name({:avro_record_type, _, _, _, _, _, full_name, _}) do
    to_string(full_name)
  end

  @doc """
  Inject cache entry for ref and schema.

  This is useful when you have multiple fingerprints for the same schema,
  e.g. due to whitespace differences
  """
  @spec cache_schema(list(ref), binary, boolean) :: :ok | {:error, term}
  def cache_schema(refs, schema, persistent \\ true)
  def cache_schema(refs, schema, persistent) when is_binary(schema) do
    case process_schema(schema) do
      {:ok, entry} ->
        for ref <- refs do
          # Logger.debug("cache_schema: #{inspect ref}")
          cache_insert(ref, entry, persistent)
        end
        :ok
      {:error, reason} ->
        {:error, reason}
    end
  end
  @spec cache_schema(ref, binary, boolean) :: :ok | {:error, term}
  def cache_schema(ref, schema, persistent) when is_binary(schema) do
    cache_schema([ref], schema, persistent)
  end

  # GenServer callbacks

  @doc "Start the GenServer."
  @spec start_link(list, list) :: {:ok, pid} | {:error, any}
  def start_link(args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Stop the GenServer"
  @spec stop() :: :ok
  def stop() do
    GenServer.call(__MODULE__, :stop)
  end

  @impl true
  def init(args) do
    Logger.info("init: #{inspect args}")
    refresh_cycle = (args[:refresh_cycle] || 60) * 1000
    ttl = args[:ttl] || 3600
    cache_dir = args[:cache_dir]
    persistent = if cache_dir, do: true, else: false
    client = ConfluentSchemaRegistry.client(args[:client] || [])

    # Logger.info("Starting with refresh cycle #{refresh_cycle}")

    :ets.new(@ets_table, [:named_table, :set, :public, {:read_concurrency, true}])

    load_cache(cache_dir)

    # Use start_timer instead of :timer.send_interval/2, as it may take
    # some time to connect to the server and/or process the results
    state = %{
      refresh_cycle: refresh_cycle,
      ttl: ttl,
      persistent: persistent,
      client: client,
      ref: :erlang.start_timer(refresh_cycle, self(), :refresh)
    }

    {:ok, state}
  end

  defp load_cache(nil), do: :ok
  defp load_cache(cache_dir) do
    path = to_charlist(Path.join(cache_dir, "#{@dets_table}.dets"))
    case :dets.open_file(@dets_table, [file: path]) do
      {:error, reason} ->
        Logger.error("Error opening DETS file #{path}: #{inspect reason}")
      {:ok, ref} ->
        Logger.debug("DETS info #{inspect ref}: #{inspect :dets.info(ref)}")
        case :dets.to_ets(ref, @ets_table) do
          {:error, reason} ->
            Logger.error("Error loading data from DETS table #{path}: #{inspect reason}")
          _ ->
            Logger.debug("Initialized ETS cache from DETS table #{path}")
        end
    end
    :ok
  end

  @impl true
  def handle_call({:get_schema, ref}, _from, state) do
    client = state[:client]
    persistent = state[:persistent]
    response = cache_apply(ref, &do_get_schema/2, [client | [ref]], persistent)
    {:reply, response, state}
  end

  def handle_call({:register_schema, subject, schema}, _from, state) do
    client = state[:client]
    persistent = state[:persistent]
    response = cache_apply({subject, schema}, &do_register_schema/3, [client | [subject, schema]], persistent)
    {:reply, response, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state[:persistent] do
      case :dets.close(@dets_table) do
        {:error, message} ->
          Logger.error("Error closing DETS table #{@dets_table}: #{inspect message}")
        :ok ->
          :ok
      end
    end

    :ok
  end

  # Get schema from registry, parse and create encoder and decoder
  @spec do_get_schema(client, ref) :: {:ok, map} | {:error, term}
  defp do_get_schema(client, ref) when is_integer(ref) do
    case ConfluentSchemaRegistry.get_schema(client, ref) do
      {:ok, schema} ->
        process_schema(schema)
      {:error, code, reason} ->
        {:error, {:confluent_schema_registry, code, reason}}
    end
  end
  defp do_get_schema(client, {_name, _fp} = ref) do
    subject = make_subject(ref)
    # Fingerprint is unique, so version is always 1
    version = 1
    case ConfluentSchemaRegistry.get_schema(client, subject, version) do
      {:ok, %{"schema" => schema}} ->
        process_schema(schema)
      {:error, code, reason} ->
        {:error, {:confluent_schema_registry, code, reason}}
      error -> error
    end
  end

  @spec process_schema(binary | :avro.type) :: {:ok, map} | {:error, term}
  defp process_schema(schema) when is_binary(schema) do
    case parse_schema(schema) do
      {:ok, parsed} ->
        process_schema(parsed)
      {:error, reason} ->
        {:error, {:parse_schema, reason}}
    end
  end
  defpprocess_schema(schema) do
    encoder = :avro.make_simple_encoder(schema, [])
    decoder = :avro.make_simple_decoder(schema, [])
    {:ok, %{schema: schema, encoder: encoder, decoder: decoder}}
  end

  @doc "Register schema"
  @spec do_register_schema(client, binary, binary | :avro.type()) :: {:ok, regid} | {:error, term}
  def do_register_schema(client, subject, schema) when is_binary(schema) do
    case ConfluentSchemaRegistry.register_schema(client, subject, schema) do
      {:ok, %{"id" => regid}} ->
        {:ok, regid}
      {:error, code, reason} ->
        {:error, {:confluent_schema_registry, code, reason}}
    end
  end

  # Internal functions, also used for testing

  @doc false
  # Look up value in cache by key
  @spec cache_lookup(term) :: term | nil
  def cache_lookup(key) do
    try do
      case :ets.lookup(@ets_table, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    catch
      # This may fail if clients make calls before the table is created
      :error, :badarg ->
        Logger.error("badarg")
        nil
    end
  end

  # Internal, may be public so that they can be used by tests

  # Run function and cache results if successful
  @spec cache_apply(term, fun, list(any), boolean) :: any
  defp cache_apply(key, fun, args, persistent) do
    case cache_lookup(key) do
      nil ->
        # Logger.debug("cache_apply: #{inspect key} not found")
        case apply(fun, args) do
          {:ok, result} ->
            cache_insert(key, result, persistent)
            {:ok, result}
          error ->
            error
        end
      value ->
        # Logger.debug("cache_apply: #{inspect key} #{inspect value}")
        {:ok, value}
    end
  end

  # Insert into ETS and optionally DETS
  @spec cache_insert(term, term, boolean) :: :ok | :error
  defp cache_insert(key, value, persistent)
  defp cache_insert(key, value, false) do
    ets_insert(key, value)
  end
  defp cache_insert(key, value, _) do
    ets_insert(key, value)
    dets_insert(key, value)
  end

  # Put value in ETS cache
  @spec ets_insert(term, term) :: :ok | :error
  defp ets_insert(key, value) do
    # Logger.debug("ETS insert #{inspect key} = #{inspect value}")
    # Logger.debug("ETS insert #{inspect key}")

    try do
      :ets.insert(@ets_table, {key, value})
    catch
      # This may fail if clients make calls before the table is created
      :error, :badarg ->
        :error
    end
  end

  # Put value in DETS cache
  @spec dets_insert(term, term) :: :ok | :error
  defp dets_insert(key, value) do
    # Logger.debug("DETS insert #{inspect key} = #{inspect value}")
    # Logger.debug("DETS insert #{inspect key}")

    try do
      # DETS insert succeeds even if there is no table open :-/
      case :dets.insert(@dets_table, {key, value}) do
        :ok ->
          :ok
        {:error, reason} ->
          Logger.warn("Could not insert to DETS table #{@dets_table}: #{inspect reason}")
          :error
      end
    catch
      :error, :badarg ->
        :error
    end
  end

  @doc false
  # Dump cache
  def dump do
    :ets.foldl(fn (entry, acc) -> [entry | acc] end, [], @ets_table)
  end
end
