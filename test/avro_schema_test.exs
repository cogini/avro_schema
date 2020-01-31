defmodule AvroSchemaTest do
  use ExUnit.Case

  # doctest AvroSchema

  @default_schema "{\"name\":\"test\",\"type\":\"record\",\"fields\":[{\"name\":\"field1\",\"type\":\"string\"},{\"name\":\"field2\",\"type\":\"int\"}]}"
  @null_schema "{\"name\":\"test\",\"type\":\"record\",\"fields\":[{\"name\":\"field1\",\"type\":\"null\"}]}"

  setup context do
    schema_json =
      case context[:schema] do
        nil -> @default_schema
        :null -> @null_schema
        name -> raise "Schema #{inspect name} not provided"
      end

    {:ok, schema} = AvroSchema.parse_schema(schema_json)

    {:ok, schema_json: schema_json, schema: schema}
  end

  test "canonicalize_schema", %{schema_json: schema_json} do

    original_json = """
    {
      "type": "record",
      "name": "test",
      "fields":
        [
          {
            "type": "string",
            "name": "field1"
          },
          {
            "type": "int",
            "name": "field2"
          }
        ]
    }
    """

    json = original_json
           |> AvroSchema.canonicalize_schema()
           |> AvroSchema.normalize_json()

    assert json == schema_json
  end

  test "fingerprint_schema", %{schema_json: schema_json} do
    assert AvroSchema.fingerprint_schema(schema_json) == <<172, 194, 58, 14, 16, 237, 158, 12>>
  end

  test "tag", %{schema_json: schema_json} do
    fp = AvroSchema.fingerprint_schema(schema_json)
    regid = 7
    payload = "hello"

    tagged_avro = AvroSchema.tag(payload, fp)
    assert tagged_avro == [<<0xC3, 0x01>>, fp, payload]

    tagged_confluent = AvroSchema.tag(payload, regid)
    assert tagged_confluent == [<<0, 0, 0, 0, 7>>, payload]
  end

  test "untag", %{schema_json: schema_json} do
    fp = AvroSchema.fingerprint_schema(schema_json)
    regid = 7
    payload = "hello"

    tagged_avro = IO.iodata_to_binary(AvroSchema.tag(payload, fp))
    tagged_confluent = IO.iodata_to_binary(AvroSchema.tag(payload, regid))

    assert {:ok, {{:avro, fp}, "hello"}} == AvroSchema.untag(tagged_avro)
    assert {:ok, {{:confluent, regid}, "hello"}} == AvroSchema.untag(tagged_confluent)

    assert {:error, :unknown_tag} == AvroSchema.untag(payload)
  end

  test "get_schema cached", %{schema_json: schema_json} do
    {:ok, schema} = AvroSchema.parse_schema(schema_json)
    :ok = AvroSchema.cache_schema(1, schema, true)
    assert {:ok, schema} == AvroSchema.get_schema(1)

    full_name = AvroSchema.full_name(schema_json)
    fp = AvroSchema.fingerprint_schema(schema_json)
    ref = {full_name, fp}
    :ok = AvroSchema.cache_schema(ref, schema, true)
    assert {:ok, schema} == AvroSchema.get_schema(ref)
  end

  test "encode/decode", %{schema_json: schema_json} do
    full_name = AvroSchema.full_name(schema_json)
    fp = AvroSchema.fingerprint_schema(schema_json)
    ref = {full_name, fp}
    :ok = AvroSchema.cache_schema(ref, schema_json, true)
    :ok = AvroSchema.cache_schema(1, schema_json, true)

    {:ok, encoder} = AvroSchema.make_encoder(schema_json)

    data_binary_keys = %{"field1" => "hello", "field2" => 21}
    data_atom_keys = %{field1: "hello", field2: 21}
    encoded = AvroSchema.encode(data_atom_keys, encoder)
    encoded_bin = IO.iodata_to_binary(encoded)

    tagged = AvroSchema.tag(encoded, fp)
    tagged_bin = IO.iodata_to_binary(tagged)

    assert {:ok, {{:avro, fp}, encoded_bin}} == AvroSchema.untag(tagged_bin)

    {:ok, decoder} = AvroSchema.get_decoder({full_name, fp})
    assert data_binary_keys == AvroSchema.decode(encoded_bin, decoder)
    assert data_binary_keys == AvroSchema.decode(encoded, decoder)

    assert {:ok, decoder} == AvroSchema.make_decoder(schema_json)
    assert {:ok, decoder} == AvroSchema.get_decoder({:confluent, 1})
    assert {:ok, encoder} == AvroSchema.get_encoder(ref)
  end

  @tag schema: :null
  test "nil values are encoded for null schema values", %{schema_json: schema_json} do
    {:ok, encoder} = AvroSchema.make_encoder(schema_json)

    null_value = %{field1: :null}
    nil_value = %{field1: nil}

    encoded = AvroSchema.encode(null_value, encoder)
    assert is_list(encoded)

    encoded = AvroSchema.encode(nil_value, encoder)
    assert is_list(encoded)
  end

  test "subject", %{schema_json: schema_json} do
    full_name = AvroSchema.full_name(schema_json)
    fp = AvroSchema.fingerprint_schema(schema_json)
    ref = {full_name, fp}
    fp_hex = AvroSchema.to_hex(fp)

    subject = "#{full_name}-#{fp_hex}"
    assert subject == AvroSchema.make_subject(ref)
    assert subject == AvroSchema.make_subject(full_name, fp)
  end

  test "parse_schema", %{schema_json: schema_json} do
    {:ok, schema} = AvroSchema.parse_schema(schema_json)
    assert schema_json == AvroSchema.encode_schema(schema)

    # catch_error {:ok, "whatever"} == AvroSchema.parse_schema("hello")
    assert {:error, "argument error"} == AvroSchema.parse_schema("hello")
  end

  test "register_schema", %{schema_json: schema_json} do
    full_name = AvroSchema.full_name(schema_json)
    :ok = AvroSchema.cache_registration(full_name, schema_json, 1, true)
    {:ok, 1} = AvroSchema.register_schema(full_name, schema_json)
  end

  test "timestamps" do
    datetime = ~U[2019-11-08 06:54:24.234207Z]
    timestamp = AvroSchema.to_timestamp(datetime)
    assert 1_573_196_064_234_207 == timestamp
    assert datetime == AvroSchema.to_datetime(timestamp)
  end

  test "get_schema_files", %{schema_json: schema_json} do
    {:ok, files} = AvroSchema.get_schema_files("test/schemas")
    assert files == ["test/schemas/test.avsc"]

    for file <- files do
      {:ok, _refs} = AvroSchema.cache_schema_file(file)
    end

    {:ok, raw} = File.read("test/schemas/test.avsc")
    fp = AvroSchema.create_fingerprint(raw)
    full_name = AvroSchema.full_name(raw)

    {:ok, schema} = AvroSchema.parse_schema(schema_json)
    assert {:ok, schema} == AvroSchema.get_schema({full_name, fp})
  end

  @tag :live_registry
  test "really interact with schema registry" do

    schema_json = "{\"name\":\"avro_schema\",\"type\":\"record\",\"fields\":[{\"name\":\"field1\",\"type\":\"string\"},{\"name\":\"field2\",\"type\":\"int\"}]}"
    {:ok, schema} = AvroSchema.parse_schema(schema_json)
    full_name = AvroSchema.full_name(schema)

    assert {:ok, 61} == AvroSchema.register_schema(full_name, schema_json)
    assert {:ok, schema} == AvroSchema.get_schema(61)

    {:error, {:confluent_schema_registry, 404, result}} = AvroSchema.get_schema(20)
    assert result["error_code"] == 40_403
    # {:error, {:confluent_schema_registry, 0, :econnrefused}}
  end

end
