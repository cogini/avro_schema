defmodule AvroSchema do
  @moduledoc File.read!("README.md")

  use GenServer

  require Logger

  @app :avro_schema
  @dets_table @app
  @ets_table __MODULE__

  # Public API

  # Types
  @typedoc "Integer ID returned by Schema Registry"
  @type regid() :: pos_integer()

  @typedoc "Subject in Schema Registry / Avro name"
  @type subject() :: binary()

  @typedoc "Fingerprint, normally CRC-64-AVRO but could be e.g. MD5"
  @type fp() :: binary()

  @type decoded() :: map | [{binary, term}]

  @typedoc "Cache key"
  @type ref() :: regid() | {subject(), fp()}

  @typedoc "Cache value"
  @type cache_value :: list({ref, :avro.avro_type()}) | {{binary(), binary()}, integer()}

  @typedoc "Tesla client"
  @type client() :: Tesla.Client.t()

  @doc """
  Tag Avro binary data with schema that created it.

  Adds a tag to the front of data indicating the schema that was used
  to encode it.

  Uses
  [Confluent wire format](https://docs.confluent.io/current/schema-registry/serializer-formatter.html#wire-format)
  for integer registry IDs and
  [Avro single object encoding](https://avro.apache.org/docs/1.8.2/spec.html#single_object_encoding_spec)
  for fingerprints.

  This function matches schema IDs as integers and encodes them using Confluent
  format, and fingerprints as binary and encodes them as Avro.

  Strictly speaking, however, fingerprints are integers, so make sure that you
  convert them to binary before calling this function.

  Note that this function returns an iolist for efficiency, not a binary.

  ## Examples

      iex> schema_json = "{\"name\":\"test\",\"type\":\"record\",\"fields\":[{\"name\":\"field1\",\"type\":\"string\"},{\"name\":\"field2\",\"type\":\"int\"}]}"
      iex> fp = AvroSchema.fingerprint_schema(schema_json)
      iex> AvroSchema.tag("hello", fp)
      [<<195, 1>>, <<172, 194, 58, 14, 16, 237, 158, 12>>, "hello"]

  """
  @spec tag(iodata, regid | fp) :: iolist
  def tag(bin, fp) when is_binary(fp) do
    [<<0xC3, 0x01>>, fp, bin]
    # [<<0xC3, 0x01, fp::unsigned-little-64>>, bin]
  end

  def tag(bin, regid) when is_integer(regid) do
    [<<0, regid::unsigned-big-32>>, bin]
  end

  @doc """
  Split schema tag from tagged Avro binary data.

  Supports [Confluent wire format](https://docs.confluent.io/current/schema-registry/serializer-formatter.html#wire-format)
  for integer registry IDs and [Avro single object encoding](https://avro.apache.org/docs/1.8.2/spec.html#single_object_encoding_spec)
  for fingerprints.

  ## Examples

    iex> tagged_avro = IO.iodata_to_binary([<<195, 1>>, <<172, 194, 58, 14, 16, 237, 158, 12>>, "hello"])
    iex> AvroSchema.untag(tagged_avro)
    {:ok, {{:avro, <<172, 194, 58, 14, 16, 237, 158, 12>>}, "hello"}}

    iex> tagged_confluent = IO.iodata_to_binary([<<0, 0, 0, 0, 7>>, "hello"])
    iex> AvroSchema.untag(tagged_confluent)
    {:ok, {{:confluent, 7}, "hello"}}
  """
  @spec untag(iodata) ::
          {:ok, {{:confluent, regid}, binary}}
          | {:ok, {{:avro, fp}, binary}}
          | {:error, :unknown_tag}
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
  Get schema for schema reference.

  This tries to read the schema from the cache. If not found, it makes a call
  to the Schema Registry.

  This is typically called by a Kafka consumer to find the schema which was
  used to encode data based on the tag.

  This call has the overhead of an ETS lookup and potentially a GenServer call
  to fetch the Avro schema via HTTP. If you need maximum performance, keep the
  result and reuse it for future requests with the same reference.
  """
  @spec get_schema(ref) :: {:ok, :avro.avro_type()} | {:error, term}
  def get_schema(ref) do
    case cache_lookup(ref) do
      nil ->
        GenServer.call(__MODULE__, {:get_schema, ref})

      value ->
        {:ok, value}
    end
  end

  @doc """
  Cache schema locally.

  Inserts the schema in the local cache under one or more references.

  `get_schema/1` will then return the schema without needing to communicate
  with the Schema Registry.

  ## Examples

      iex> schema_json = "{\"name\":\"test\",\"type\":\"record\",\"fields\":[{\"name\":\"field1\",\"type\":\"string\"},{\"name\":\"field2\",\"type\":\"int\"}]}"
      iex> {:ok, schema} = AvroSchema.parse_schema(schema_json)
      iex> full_name = AvroSchema.full_name(schema_json)
      iex> fp = AvroSchema.fingerprint_schema(schema_json)
      iex> ref = {full_name, fp}
      iex> :ok = AvroSchema.cache_schema(ref, schema)
      :ok
  """
  @spec cache_schema(ref | list(ref), binary | :avro.avro_type(), boolean) :: :ok | {:error, term}
  def cache_schema(refs, schema, persistent \\ false)

  def cache_schema(refs, schema, persistent) when is_list(refs) do
    case process_schema(schema) do
      {:ok, value} ->
        objects = Enum.map(refs, &{&1, value})
        cache_insert(objects, persistent)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cache_schema(ref, schema, persistent), do: cache_schema([ref], schema, persistent)

  # TODO
  @doc """
  Register schema in Confluent Schema Registry.

  The subject is a unique name to register the schema, often the full name from the Avro schema.
  See the [standard strategies](https://docs.confluent.io/current/schema-registry/serializer-formatter.html#subject-name-strategy)
  used by Confluent in their Kafka libraries.

  It is safe to register the same schema multiple times, it will always return
  the same ID.
  """
  @spec register_schema(subject, binary) :: {:ok, regid} | {:error, term}
  def register_schema(subject, schema) when is_binary(schema) do
    case cache_lookup({subject, schema}) do
      nil ->
        GenServer.call(__MODULE__, {:register_schema, subject, schema})

      value ->
        {:ok, value}
    end
  end

  @doc """
  Cache registration.

  Inserts the schema in the local cache.

  `register_schema/1` will then return the id without needing to communicate
  with the Schema Registry.
  """
  @spec cache_registration(binary(), binary(), integer(), boolean()) :: :ok | :error
  def cache_registration(subject, schema, regid, persistent \\ false) when is_binary(schema) do
    cache_insert({{subject, schema}, regid}, persistent)
  end

  @doc """
  Make Avro decoder for schema.

  Creates a function which decodes a Avro encoded binary data to a map. By default,
  a `:hook` option is provided that will convert all `:null` values to `nil`.
  """
  @spec make_decoder(binary | :avro.avro_type(), Keyword.t()) :: {:ok, fun} | {:error, term}
  def make_decoder(schema, decoder_opts \\ [record_type: :map, map_type: :map])

  def make_decoder(schema_json, decoder_opts) when is_binary(schema_json) do
    case parse_schema(schema_json) do
      {:ok, schema} ->
        make_decoder(schema, decoder_opts)

      error ->
        error
    end
  end

  def make_decoder(schema, decoder_opts) do
    decoder_opts = Keyword.put_new(decoder_opts, :hook, &decoder_hook/4)
    {:ok, :avro.make_simple_decoder(schema, decoder_opts)}
  end

  @doc """
  Get decoder function for registration id.

  Convenience function, calls `get_schema/1` on the id, then `make_decoder/2`.
  """
  @spec get_decoder(ref | {:confluent, regid}, Keyword.t()) :: {:ok, fun} | {:error, term}
  def get_decoder(ref, decoder_opts \\ [record_type: :map, map_type: :map])
  def get_decoder({:confluent, regid}, decoder_opts), do: get_decoder(regid, decoder_opts)

  def get_decoder(ref, decoder_opts) do
    case get_schema(ref) do
      {:ok, schema} ->
        make_decoder(schema, decoder_opts)

      error ->
        error
    end
  end

  defp decoder_hook(type, _sub_info, data, decode_fn) do
    case :avro.get_type_name(type) do
      "null" -> {nil, data}
      _ -> decode_fn.(data)
    end
  end

  # TODO
  @doc """
  Make Avro encoder for schema.

  Creates a function which encodes Avro terms to binary.
  """
  @spec make_encoder(binary | :avro.avro_type(), Keyword.t()) :: {:ok, fun} | {:error, term}
  def make_encoder(schema_json, encoder_opts \\ [])

  def make_encoder(schema_json, encoder_opts) when is_binary(schema_json) do
    case parse_schema(schema_json) do
      {:ok, schema} ->
        make_encoder(schema, encoder_opts)

      error ->
        error
    end
  end

  def make_encoder(schema, encoder_opts) do
    {:ok, :avro.make_simple_encoder(schema, encoder_opts)}
  end

  @doc """
  Get encoder function for registration id.

  Convenience function, calls `get_schema/1` on the id, then `make_encoder/2`.
  """
  @spec get_encoder(ref, Keyword.t()) :: {:ok, fun} | {:error, term}
  def get_encoder(ref, encoder_opts \\ []) do
    case get_schema(ref) do
      {:ok, schema} ->
        make_encoder(schema, encoder_opts)

      error ->
        error
    end
  end

  # @spec decode(binary) :: {:ok, map | [{binary, term}]} | {:error, term}
  # def decode(tagged_bin) do
  #   with {:ok, {{:confluent, regid}, data}} <- untag(tagged_bin),
  #        {:ok, schema} <- get_schema(regid)
  #   do
  #     {:ok, decoder.(data)}
  #   else
  #     error -> error
  #   end
  # end

  @doc "Decode binary Avro data."
  @spec decode(binary, fun) :: {:ok, decoded()} | {:error, term()}
  def decode(bin, decoder) do
    {:ok, decoder.(bin)}
  rescue
    error -> {:error, error}
  end

  @doc "Decode binary Avro data, raises if there is a decoding error"
  @spec decode!(binary, fun) :: decoded()
  def decode!(bin, decoder) do
    decoder.(bin)
  end

  @doc "Encode Avro data to binary."
  @spec encode(map | [{binary, term}], fun) :: {:ok, binary} | {:error, term()}
  def encode(data, encoder) do
    {:ok, encoder.(data)}
  rescue
    error -> {:error, error}
  end

  @doc "Encode Avro data to binary, raises if there is an encoding error"
  @spec encode!(map | [{binary, term}], fun) :: binary
  def encode!(data, encoder) do
    encoder.(data)
  end

  @doc """
  Create fingerprint of schema JSON.

  Ensures that schema is in standard form, then generates an
  CRC-64-AVRO fingerprint on it using `create_fingerprint/1`.

  ## Examples

      iex> schema_json = "{\"name\":\"test\",\"type\":\"record\",\"fields\":[{\"name\":\"field1\",\"type\":\"string\"},{\"name\":\"field2\",\"type\":\"int\"}]}"
      iex> AvroSchema.fingerprint_schema(schema_json)
      <<172, 194, 58, 14, 16, 237, 158, 12>>

  """
  @spec fingerprint_schema(binary) :: fp
  def fingerprint_schema(schema) do
    schema
    |> canonicalize_schema()
    |> normalize_json()
    |> create_fingerprint()
  end

  @doc """
  Create CRC-64-AVRO fingerprint hash for Avro schema JSON.

  See [CRC-64-AVRO](https://avro.apache.org/docs/1.8.2/spec.html#schema_fingerprints)

  ## Examples

      iex> schema_json = "{\"name\":\"test\",\"type\":\"record\",\"fields\":[{\"name\":\"field1\",\"type\":\"string\"},{\"name\":\"field2\",\"type\":\"int\"}]}"
      iex> AvroSchema.fingerprint_schema(schema_json)
      <<172, 194, 58, 14, 16, 237, 158, 12>>
  """
  @spec create_fingerprint(binary) :: fp
  def create_fingerprint(binary) do
    <<:avro.crc64_fingerprint(binary)::little-size(64)>>
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
  Normalize JSON by decoding and re-encoding it.

  This reduces irrelevant differences such as whitespace which may affect
  fingerprinting.
  """
  @spec normalize_json(binary) :: binary
  def normalize_json(json) do
    parsed_json = :jsone.decode(json, object_format: :tuple)
    :jsone.encode(parsed_json)
  end

  @doc "Encode parsed schema as JSON."
  @spec encode_schema(:avro.avro_type(), Keyword.t()) :: binary
  def encode_schema(schema, opts \\ []) do
    :avro.encode_schema(schema, opts)
  end

  @doc "Make registration subject from name + fingerprint."
  @spec make_fp_subject({binary, fp}) :: binary
  def make_fp_subject({name, fp}) when is_binary(fp), do: "#{name}-#{to_hex(fp)}"

  @spec make_fp_subject(binary, fp) :: binary
  def make_fp_subject(name, fp) when is_binary(fp), do: make_fp_subject({name, fp})

  @doc "
  Get full name field from schema.

  This can be used as the Schema Registry subject.
  "
  @spec full_name(:avro.avro_type() | binary) :: binary
  def full_name(schema_json) when is_binary(schema_json) do
    {:ok, schema} = parse_schema(schema_json)
    full_name(schema)
  end

  def full_name({:avro_record_type, _, _, _, _, _, full_name, _}) do
    to_string(full_name)
  end

  @doc """
  Parse schema into Avro library internal form.

  ## Examples

    iex> schema_json = "{\"name\":\"test\",\"type\":\"record\",\"fields\":[{\"name\":\"field1\",\"type\":\"string\"},{\"name\":\"field2\",\"type\":\"int\"}]}"
    iex> {:ok, schema} = AvroSchema.parse_schema(schema_json)
    {:ok,
     {:avro_record_type, "test", "", "", [],
      [
        {:avro_record_field, "field1", "", {:avro_primitive_type, "string", []},
          :undefined, :ascending, []},
  """
  @spec parse_schema(binary) :: {:ok, :avro.avro_type()} | {:error, term}
  def parse_schema(json) do
    avro_type = :avro.decode_schema(json)
    lkup = :avro.make_lkup_fun(avro_type)
    {:ok, :avro.expand_type_bloated(avro_type, lkup)}
  rescue
    # e in RuntimeError -> {:error, e}
    e in ArgumentError ->
      {:error, e.message}
      # e in ErlangError -> {:error, e.original}
  end

  @doc """
  Convert `DateTime` to Avro integer timestamp with ms precision.

  ## Examples

      iex> datetime = DateTime.utc_now()
      ~U[2019-11-08 09:09:01.055742Z]

      iex> timestamp = AvroSchema.to_timestamp(datetime)
      1573204141055742
  """
  @spec to_timestamp(DateTime.t()) :: non_neg_integer
  def to_timestamp(date_time) do
    DateTime.to_unix(date_time, :microsecond)
  end

  @doc """
  Convert Avro integer timestamp to `DateTime`.

      iex> timestamp = 1573204141055742
      iex> datetime = AvroSchema.to_datetime(timestamp)
      ~U[2019-11-08 09:09:01.055742Z]
  """
  def to_datetime(timestamp) do
    {:ok, datetime} = DateTime.from_unix(timestamp, :microsecond)
    datetime
  end

  @doc """
  List schema files in directory.

  Lists files in a directory matching an extension, default `avsc`.
  """
  @spec get_schema_files(Path.t()) :: {:ok, list(Path.t())} | {:error, File.posix()}
  def get_schema_files(dir, ext \\ "avsc") do
    {:ok, re} = Regex.compile("#{ext}$")

    case File.ls(dir) do
      {:ok, files} ->
        paths =
          files
          |> Enum.filter(&Regex.match?(re, &1))
          |> Enum.map(&Path.join(dir, &1))

        {:ok, paths}

      error ->
        error
    end
  end

  @doc """
  Cache schema files with fingerprints.

  Loads a schema file from disk, and parses it to get the full name.

  Generates fingerprints for the schema using the raw file bytes,
  [Parsing Canonical Form](https://avro.apache.org/docs/1.8.2/spec.html#Parsing+Canonical+Form+for+Schemas),
  and normalized JSON for the canonical form (whitespace stripped).
  This improves interop with fingerprints generated by other programs,
  avoiding insignificant differences.

  Also accepts a map with aliases that the schema should be registered
  under, e.g. with a different subject name or legacy fingerprint.
  Map key is the full name, and value is a list of fingerprints or
  `{name, fingerprint}` tuples.

  Deduplicates the fingerprints and aliases, then calls `cache_schema/3`.
  """
  @spec cache_schema_file(Path.t(), map) :: {:ok, list({binary, binary})} | {:error, term}
  def cache_schema_file(path, subject_aliases \\ %{}) do
    {:ok, json} = File.read(path)
    {:ok, schema} = AvroSchema.parse_schema(json)
    full_name = AvroSchema.full_name(schema)

    # Logger.info("full_name #{full_name}")

    # Put schema in Parsing Canonical Form
    canon_json = AvroSchema.canonicalize_schema(json)
    normal_json = AvroSchema.normalize_json(canon_json)

    primary_ref = {full_name, AvroSchema.create_fingerprint(normal_json)}

    intermediate_refs =
      for bin <- [json, canon_json] do
        {full_name, AvroSchema.create_fingerprint(bin)}
      end

    aliases = subject_aliases[full_name] || []

    alias_refs =
      Enum.map(aliases, fn
        fp when is_binary(fp) -> {full_name, fp}
        {_name, _fp} = a -> a
      end)

    refs = Enum.uniq([primary_ref] ++ intermediate_refs ++ alias_refs)

    # for {subject, fp} <- refs do
    #   fp_hex = Base.encode16(fp, case: :lower)
    #   Logger.debug("Registering #{subject} #{fp_hex}")
    # end
    case AvroSchema.cache_schema(refs, normal_json) do
      :ok ->
        {:ok, refs}

      error ->
        error
    end
  end

  @doc "Convert binary fingerprint to hex"
  @spec to_hex(fp) :: binary
  def to_hex(fp), do: Base.encode16(fp, case: :lower)

  # GenServer callbacks

  @doc "Start cache GenServer."
  @spec start_link(list, list) :: {:ok, pid} | {:error, any}
  def start_link(args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Stop cache GenServer"
  @spec stop() :: :ok
  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @impl GenServer
  def init(args) do
    # Logger.info("init: #{inspect args}")
    cache_dir = args[:cache_dir]
    persistent = if cache_dir, do: true, else: false
    client = ConfluentSchemaRegistry.client(args[:client] || [])

    # Logger.info("Starting with refresh cycle #{refresh_cycle}")

    @ets_table = :ets.new(@ets_table, [:named_table, :set, :public, {:read_concurrency, true}])

    load_cache(cache_dir)

    state = %{
      persistent: persistent,
      client: client
    }

    {:ok, state}
  end

  defp load_cache(nil), do: :ok

  defp load_cache(cache_dir) do
    path = to_charlist(Path.join(cache_dir, "#{@dets_table}.dets"))

    case :dets.open_file(@dets_table, file: path) do
      {:error, reason} ->
        Logger.error("Error opening DETS file #{path}: #{inspect(reason)}")

      {:ok, ref} ->
        # Logger.debug("DETS info #{inspect ref}: #{inspect :dets.info(ref)}")
        case :dets.to_ets(ref, @ets_table) do
          {:error, reason} ->
            Logger.error("Error loading data from DETS table #{path}: #{inspect(reason)}")

          _ ->
            # Logger.debug("Initialized ETS cache from DETS table #{path}")
            :ok
        end
    end

    :ok
  end

  @impl GenServer
  def handle_call({:get_schema, ref}, _from, state) do
    client = state[:client]
    persistent = state[:persistent]
    response = cache_apply(ref, &do_get_schema/2, [client | [ref]], persistent)
    {:reply, response, state}
  end

  def handle_call({:register_schema, subject, schema}, _from, state) do
    client = state[:client]
    persistent = state[:persistent]

    response =
      cache_apply(
        {subject, schema},
        &do_register_schema/3,
        [client | [subject, schema]],
        persistent
      )

    {:reply, response, state}
  end

  @impl GenServer
  def terminate(_reason, %{persistent: true}) do
    case :dets.close(@dets_table) do
      {:error, message} ->
        Logger.error("Error closing DETS table #{@dets_table}: #{inspect(message)}")

      :ok ->
        :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  # Get schema from registry, parse and create encoder and decoder
  @spec do_get_schema(client, ref) :: {:ok, :avro.avro_type()} | {:error, term}
  defp do_get_schema(client, ref) when is_integer(ref) do
    case ConfluentSchemaRegistry.get_schema(client, ref) do
      {:ok, schema} ->
        process_schema(schema)

      {:error, code, reason} ->
        {:error, {:confluent_schema_registry, code, reason}}
    end
  end

  defp do_get_schema(client, {_name, _fp} = ref) do
    subject = make_fp_subject(ref)
    # Fingerprint is unique, so version is always 1
    version = 1

    case ConfluentSchemaRegistry.get_schema(client, subject, version) do
      {:ok, %{"schema" => schema}} ->
        process_schema(schema)

      {:error, code, reason} ->
        {:error, {:confluent_schema_registry, code, reason}}

      error ->
        error
    end
  end

  # Convert schema before storing in the cache
  @spec process_schema(binary | :avro.avro_type()) :: {:ok, :avro.avro_type()} | {:error, term}
  defp process_schema(schema) when is_binary(schema), do: parse_schema(schema)
  defp process_schema(schema), do: {:ok, schema}

  # @doc "Register schema"
  @spec do_register_schema(client, subject, binary | :avro.avro_type()) ::
          {:ok, regid} | {:error, term}
  defp do_register_schema(client, subject, schema) when is_binary(schema) do
    case ConfluentSchemaRegistry.register_schema(client, subject, schema) do
      {:ok, regid} ->
        {:ok, regid}

      {:error, code, reason} ->
        {:error, {:confluent_schema_registry, code, reason}}
    end
  end

  # Internal, may be public so that they can be used by tests

  @doc false
  # Look up value in cache by key
  @spec cache_lookup(term) :: term | nil
  def cache_lookup(key) do
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

  # Run function and cache results if successful
  @spec cache_apply(term, fun, list(any), boolean) :: any
  defp cache_apply(key, fun, args, persistent) do
    case cache_lookup(key) do
      nil ->
        # Logger.debug("cache_apply: #{inspect key} not found")
        case apply(fun, args) do
          {:ok, result} ->
            cache_insert([{key, result}], persistent)
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
  @spec cache_insert(cache_value(), boolean) :: :ok | :error

  # defp cache_insert(objects, persistent?) do
  #   ets_insert(objects)

  #   if persistent? do
  #     dets_insert(objects)
  #   end
  # end

  defp cache_insert(objects, persistent)

  defp cache_insert(objects, true) do
    ets_insert(objects)
    dets_insert(objects)
  end

  defp cache_insert(objects, _) do
    ets_insert(objects)
  end

  # Put value in ETS cache
  @spec ets_insert(cache_value()) :: :ok | :error
  defp ets_insert(objects) do
    :ets.insert(@ets_table, objects)
    :ok
  catch
    # This may fail if clients make calls before the table is created
    :error, :badarg ->
      :error
  end

  # Put value in DETS cache
  @spec dets_insert(cache_value()) :: :ok | :error
  defp dets_insert(objects) do
    # DETS insert succeeds even if there is no table open :-/
    case :dets.insert(@dets_table, objects) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not insert into DETS table #{@dets_table} #{inspect(reason)} #{inspect(objects)}")

        :error
    end
  catch
    :error, :badarg ->
      Logger.warning("Could not insert into DETS table #{@dets_table} badarg #{inspect(objects)}")
      :error
  end

  @doc false
  # Dump cache
  def dump do
    :ets.foldl(fn entry, acc -> [entry | acc] end, [], @ets_table)
  end
end
