# avro_schema

Convenience library for working with [Avro](https://avro.apache.org/)
schemas and the [Confluent® Schema Registry](https://www.confluent.io/confluent-schema-registry).

It is primarily focused on working with [Kafka](https://kafka.apache.org/)
streams.

This library uses [erlavro](https://github.com/klarna/erlavro) for encoding
and decoding data and [confluent_schema_registry](https://github.com/cogini/confluent_schema_registry)
to look up schemas using the [Schema Registry API](https://docs.confluent.io/current/schema-registry/develop/api.html).

It caches schemas for performance and to allow programs to work independently
of the Schema Registry being available.

## Installation

Add the package to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:avro_schema, "~> 0.1.0"}]
end
```

Then run `mix deps.get` to fetch the new dependency.

Documentation is on [HexDocs](https://hexdocs.pm/avro_schema).
To generate a local copy, run `mix docs`.

## Overview

When using Kafka, producers and consumers are separated, and schemas may evolve
over time. It is common to tag data written to Kafka to indicate the schema
which was used to encode it. Consumers can then look up the corresponding
schema and use it decode the data.

This library supports two formats, [Confluent wire format](https://docs.confluent.io/current/schema-registry/serializer-formatter.html#wire-format),
and [Avro single object encoding](https://avro.apache.org/docs/1.8.2/spec.html#single_object_encoding_spec).

### Confluent wire format

With the [Confluent wire format](https://docs.confluent.io/current/schema-registry/serializer-formatter.html#wire-format),
Avro binary encoded objects are prefixed with a five-byte tag.

The first byte indicates the Confluent serialization format version number,
currently always 0. The following four bytes encode the integer schema ID as
returned from the Schema Registry in network byte order.

### Avro single-object encoding

When used without a schema registry, it's common to prefix binary data with a
hash of the schema that created it. In the past, that might be something like
an MD5 hash.

The Avro "Single-object encoding" formalizes this, prefixing Avro binary data
with a two-byte marker, C3 01, to show that the message is Avro and uses this
single-record format (version 1). That is followed by the the 8-byte little-endian
[CRC-64-AVRO](https://avro.apache.org/docs/1.8.2/spec.html#schema_fingerprints)
fingerprint of the object's schema.

The CRC64 algorithm is uncommon, but used because it is shorter than e.g. MD5,
while still being good enough to detect collisions. The fingerprint function is
implemented in the `erlavro:crc64_fingerprint/1` function.

The Schema Registry ID is more compact in the payload (only five bytes
overhead), but relies on the registry. The fingerprint is static, and can
be obtained at compile time, but it is harder to share with other applications
and evolve over time.

### Kafka producer

A Kafka producer program needs to be able to encode the data with an Avro schema
and tag it with the schema ID or fingerprint. It normally stores the schema in
the code or reads it from a file.

It can then call the Schema Registry to get the ID matching the Avro schema and
subject:

```elixir
iex> AvroSchema.register_schema(subject, schema)
{:ok, 1}
```

The subject is a name which identifies the type of data. Multiple Kafka topics
may carry the same data, so they have the same subject. It is normally the Avro
"full name" (https://avro.apache.org/docs/1.8.2/spec.html#names), e.g.
`com.example.X`. In an Avro schema, it is the "name" field.

If the schema has already been registered, then the Schema Registry will
return the current id. If you are registering a new version of the schema, then
the Schema Registry will first check if it is compatible with the old one.
Depending on the compatibility rules, it may reject the schema.
TODO: link

The producer next needs to get an encoder for the schema.

```elixir
{:ok, encoder} = AvroSchema.make_encoder(schema)
iex>
```

The encoder is a function that takes a list of Avro key/value data and encodes
it to a binary.

```elixir
defmodule Request do
  @moduledoc "Request log"

  defstruct [
    node_name: "",  # source host of log record
    timestamp: "",  # Log time, format ISO-8601 "YYYY-MM-DDTHH:MM:SSZ"
    ip: "",         # Request IP address
    duration: 0.0,  # Processing time for request, float seconds
    host: "",       # Request host
    request_id: ""  # Unique id for request, GUID
  ]

  @type t :: %__MODULE__{
    node_name: binary,  # source host of log record
    timestamp: binary | non_neg_integer | DateTime.t, # Log time, format ISO-8601 "YYYY-MM-DDTHH:MM:SSZ"
    ip: binary,         # Request IP address
    duration: float,    # Processing time for this request, float seconds
    host: binary,       # Request host
    request_id: binary  # Unique id for request, GUID
  }

  def avro_schema do
    """
    {"type": "record", "name":"RequestLog", "namespace": "com.dmpro.bounce",
      "fields": [
        {"name": "node_name", "type": "string"},
        {"name": "timestamp", "type": "long", "logicalType": "timestamp-millis"},
        {"name": "ip", "type": "string"},
        {"name": "duration", "type": "float"},
        {"name": "host", "type": "string"},
        {"name": "request_id", "type": "string"}
      ]
    }
    """
  end

  @spec to_avro_term(t) :: map
  def to_avro_term(struct) do
    data = [
      {"node_name", struct.node_name},
      {"timestamp", struct.timestamp},
      {"ip", struct.ip},
      {"duration", struct.duration},
      {"host", struct.host},
      {"request_id", struct.request_id},
    ]
    %{type: "com.example.Request", data: data, key: struct.request_id}
  end
end

{:ok, datetime} = DateTime.now("Etc/UTC")
timestamp = AvroSchema.to_timestamp(datetime)

request = %Request{timestamp: timestamp, ....}
bin = request
      |> Request.to_avro_term()
      |> AvroSchema.encode(encoder)
      |> AvroSchema.tag(1)
```





In order to improve interoperability, the schema should be put into standard form.


It might also call the schema registry to get the schema for a given subject:

```elixir
iex> ConfluentSchemaRegistry.get_schema(client, "test")
{:ok,
%{
 "id" => 21,
 "schema" => "{\"type\":\"record\",\"name\":\"test\",\"fields\":[{\"name\":\"field1\",\"type\":\"string\"},{\"name\":\"field2\",\"type\":\"int\"}]}",
 "subject" => "test",
 "version" => 13
}}
```



## Caching

An in-memory ETS cache maps the integer registry ID or name + fingerprint
to the corresponding schema and decoder.

It also allows lookups using name and fingerprint as a key.

The fingerprint is CRC64 by default. You can also register a name with your own
fingerprint.

This library also allows consumers to look up the schema on demand from the
Schema Registry using the name + fingerprint as the registry subject name.

This library can optionally persist the cache data on disk using DETS,
allowing programs to work without continuous access to the Schema Registry.

## Performance

Programs which use Kafka may process high message volumes, so efficiency
is important. They generally use multiple processes, typically one per
topic partion or more. On startup, each process may simultaneously attempt to
look up schemas.

The cache lookup runs in the caller's process, so it can run in parallel.
If there is a cache miss, then it calls the GenServer to update the cache.
This has the effect of serializing requests, ensuring that only one runs
at a time. See https://www.cogini.com/blog/avoiding-genserver-bottlenecks/ for
discussion.

## Usage

