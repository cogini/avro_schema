![test workflow](https://github.com/cogini/avro_schema/actions/workflows/test.yml/badge.svg)
[![Module Version](https://img.shields.io/hexpm/v/avro_schema.svg)](https://hex.pm/packages/avro_schema)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/avro_schema/)
[![Total Download](https://img.shields.io/hexpm/dt/avro_schema.svg)](https://hex.pm/packages/avro_schema)
[![License](https://img.shields.io/hexpm/l/avro_schema.svg)](https://github.com/cogini/avro_schema/blob/master/LICENSE.md)
[![Last Updated](https://img.shields.io/github/last-commit/cogini/avro_schema.svg)](https://github.com/cogini/avro_schema/commits/master)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)

# AvroSchema

---

This is a library for working with [Avro](https://avro.apache.org/)
schemas and the [Confluent® Schema Registry](https://www.confluent.io/confluent-schema-registry),
primarily focused on working with [Kafka](https://kafka.apache.org/) streams.
It relies on [erlavro](https://github.com/klarna/erlavro) for encoding and
decoding data and [confluent_schema_registry](https://github.com/cogini/confluent_schema_registry)
to look up schemas using the [Schema Registry API](https://docs.confluent.io/current/schema-registry/develop/api.html).

Its primary value is that it caches schemas for performance and to allow
programs to work independently of the Schema Registry being available.
It also has a consistent set of functions to manage schema tags, look up
schemas from the Schema Registry or files, and encode/decode data.

Much thanks to Klarna for [Avlizer](https://github.com/klarna/avlizer), which
provides similar functionality to this library in Erlang,
[erlavro](https://github.com/klarna/erlavro) for Avro, and
[brod](https://github.com/klarna/brod) for dealing with Kafka.

## Installation

Add the package to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:avro_schema, "~> 0.1.0"}
  ]
end
```

Documentation is on [HexDocs](https://hexdocs.pm/avro_schema).
To generate a local copy, run `mix docs`.

## Starting

Add the cache GenServer to your application's supervision tree:

```elixir
def start(_type, _args) do
  cache_dir = Application.get_env(:yourapp, :cache_dir, "/tmp")

  children = [
    {AvroSchema, [cache_dir: cache_dir]},
  ]

  opts = [strategy: :one_for_one, name: Example.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Overview

When using Kafka, producers and consumers are separated, and schemas may evolve
over time. It is common for producers to tag data indicating the schema that
was used to encode it. Consumers can then look up the corresponding schema
version and use it decode the data.

This library supports two tagging formats, [Confluent wire format](https://docs.confluent.io/current/schema-registry/serializer-formatter.html#wire-format),
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
MD5.

The Avro "Single-object encoding" formalizes this, prefixing Avro binary data
with a two-byte marker, C3 01, to show that the message is Avro and uses this
single-record format (version 1). That is followed by the 8-byte little-endian
[CRC-64-AVRO](https://avro.apache.org/docs/1.8.2/spec.html#schema_fingerprints)
fingerprint of the object's schema.

The CRC64 algorithm is uncommon, but used because it is relatively short,
while still being good enough to detect collisions. The fingerprint function is
implemented in `fingerprint_schema/1`.

### Schema Registry

In a relatively static system, it's not too hard to exchange schema files
between producers and consumers. When things are changing more frequently, it
can be difficult to keep files up to date. It's also easy for insignificant
differences such as whitespace to result in different schema hashes.

The Schema Registry solves this by providing a centralized service which
producers and consumers can call to get a unique identifier for a schema
version. Producers register a schema with the service and get an id.
Consumers look up the id to get the schema.

The Schema Registry also does validation on new schemas to ensure that they
meet a backwards compatibility policy for the organization.
This helps to [evolve schemas](https://docs.confluent.io/current/schema-registry/avro.html)
over time and deploy them without breaking running applications.

The disadvantage of the Schema Registry is that it can be a single point
of failure. Different schema registries will, in general, assign a different
numeric id to the same schema.

This library provides functions to register schemas with the Schema Registry
and look them up by id. It caches the results in RAM (ETS) for performance,
and optionally also on disk (DETS). This gives good performance and allows
programs to work without needing to communicate with the Schema Registry.
Once read, the numeric IDs never change, so it's safe to cache them indefinitely.

The library also has support for managing schemas from files. It can add files
to the cache by fingerprint, registering the same schema under multiple
fingerprints, i.e. the raw JSON, a version in
[Parsing Canonical Form](https://avro.apache.org/docs/current/spec.html#Parsing+Canonical+Form+for+Schemas)
and with whitespace stripped out. You can also manually register aliases for the
name and fingerprint to handle legacy data.

## Kafka producer example

A Kafka producer program needs to be able to encode the data with an Avro
schema and tag it with the schema ID or fingerprint. It may store the
schema in the code or read it from a file, or it may look it up from the Schema
Registry using the subject.

The subject is a registered name which identifies the type of data.
There are are several [standard strategies](https://docs.confluent.io/current/schema-registry/serializer-formatter.html#subject-name-strategy)
used by Confluent in their Kafka libraries.

* `TopicNameStrategy`, the default, registers the schema based on the Kafka
  topic name, implicitly requiring that all messages use the same schema.

* `RecordNameStrategy` names the schema using the record type, allowing
  a single topic to have multiple different types of data or multiple topics
  to have the same type of data.

  In an Avro schema the "[full name](https://avro.apache.org/docs/1.8.2/spec.html#names)", is
  a namespace-qualified name for the record, e.g. `com.example.X`. In the schema, it is
  the `name` field.

* `TopicRecordNameStrategy` names the schema using a combination of topic and record.

With the subject, the producer can call the Schema Registry to get the ID
matching the Avro schema:

```elixir
iex> schema_json = "{\"name\":\"test\",\"type\":\"record\",\"fields\":[{\"name\":\"field1\",\"type\":\"string\"},{\"name\":\"field2\",\"type\":\"int\"}]}"
iex> subject = "test"
iex> {:ok, ref} = AvroSchema.register_schema(subject, schema_json)
{:ok, 21}
```

If the schema has already been registered, then the Schema Registry will
return the current id. If you are registering a new version of the schema, then
the Schema Registry will first check if it is compatible with the old one.
Depending on the compatibility rules, it may reject the schema.

The producer next needs to get an encoder for the schema.

The encoder is a function that takes Avro key/value data and encodes
it to a binary.

```elixir
iex> {:ok, encoder} = AvroSchema.make_encoder(schema_json)
{:ok, #Function<2.110795165/1 in :avro.make_simple_encoder/2>}
```

Next we encode some data:

```elixir
iex> data = %{field1: "hello", field2: 100}
iex> encoded = AvroSchema.encode!(data, encoder)
[['\n', "hello"], [200, 1]]
```

Finally, we tag the data:

```elixir
iex> tagged_confluent = AvroSchema.tag(encoded, 21)
[<<0, 0, 0, 0, 21>>, [['\n', "hello"], [200, 1]]]
```

If you are using files, the process is similar. First
create a fingerprint for the schema:

```elixir
iex> fp = AvroSchema.fingerprint_schema(schema_json)
<<172, 194, 58, 14, 16, 237, 158, 12>>
```

Next tag the data:

```elixir
iex> tagged_avro = AvroSchema.tag(encoded, fp)
[
  <<195, 1>>,
  <<172, 194, 58, 14, 16, 237, 158, 12>>,
  [['\n', "hello"], [200, 1]]
]
```

Now you can send the data to Kafka.

## Kafka consumer example

The process for a consumer is similar.

Receive the data and get the registration id in Confluent format:

```elixir
iex> tagged_confluent = IO.iodata_to_binary(AvroSchema.tag(encoded, 21))
<<0, 0, 0, 0, 21, 10, 104, 101, 108, 108, 111, 200, 1>>

iex> {:ok, {{:confluent, regid}, bin}} = AvroSchema.untag(tagged_confluent)
{:ok, {{:confluent, 21}, <<10, 104, 101, 108, 108, 111, 200, 1>>}}
```

Get the schema from the Schema Registry:

```elixir
iex> {:ok, schema} = AvroSchema.get_schema(regid)
{:ok,
 {:avro_record_type, "test", "", "", [],
  [
    {:avro_record_field, "field1", "", {:avro_primitive_type, "string", []},
     :undefined, :ascending, []},
    {:avro_record_field, "field2", "", {:avro_primitive_type, "int", []},
     :undefined, :ascending, []}
  ], "test", []}}
```

Create a decoder and decode the data:

```elixir
iex> {:ok, decoder} = AvroSchema.make_decoder(schema)
{:ok, #Function<4.110795165/1 in :avro.make_simple_decoder/2>}

iex> decoded = AvroSchema.decode!(bin, decoder)
%{"field1" => "hello", "field2" => 100}
```

The process is similar with a fingerprint.  In this case, we get the schema
from files and register it in the cache using the schema name and fingerprints. There
is more than one fingerprint because we register it with the raw schema from
the file and the normalized JSON for better interop.

```elixir
iex> {:ok, files} = AvroSchema.get_schema_files("test/schemas")
{:ok, ["test/schemas/test.avsc"]}

iex> for file <- files, do: AvroSchema.cache_schema_file(file)
[
  ok: [
    {"test", <<172, 194, 58, 14, 16, 237, 158, 12>>},
    {"test", <<194, 132, 80, 199, 36, 146, 103, 147>>}
  ]
]
```

To decode, separate the fingerprint from the data:

```elixir
iex> tagged_avro = IO.iodata_to_binary(AvroSchema.tag(encoded, fp))
<<195, 1, 172, 194, 58, 14, 16, 237, 158, 12, 10, 104, 101, 108, 108, 111, 200,
  1>>

iex> {:ok, {{:avro, fp}, bin}} = AvroSchema.untag(tagged_avro)
{:ok, {{:avro, <<172, 194, 58, 14, 16, 237, 158, 12>>},
  <<10, 104, 101, 108, 108, 111, 200, 1>>}}
```

Get the decoder and decode the data:

```elixir
iex> {:ok, schema} = AvroSchema.get_schema({"test", fp})
{:ok,
 {:avro_record_type, "test", "", "", [],
  [
    {:avro_record_field, "field1", "", {:avro_primitive_type, "string", []},
     :undefined, :ascending, []},
    {:avro_record_field, "field2", "", {:avro_primitive_type, "int", []},
     :undefined, :ascending, []}
  ], "test", []}}
```

Decoding works the same as with the Schema Registry:

```elixir
iex> {:ok, decoder} = AvroSchema.make_decoder(schema)
{:ok, #Function<4.110795165/1 in :avro.make_simple_decoder/2>}

iex> decoded = AvroSchema.decode!(bin, decoder)
%{"field1" => "hello", "field2" => 100}
```


## Performance

For best performance, save the encoder or decoder in your process
state to avoid the overhead of looking it up for each message.

An in-memory ETS cache maps the integer registry ID or name + fingerprint
to the corresponding schema and decoder. It also allows lookups using name and
fingerprint as a key.

The fingerprint is CRC64 by default. You can also register a name with your own
fingerprint.

This library also allows consumers to look up the schema on demand from the
Schema Registry using the name + fingerprint as the registry subject name.

This library can optionally persist the cache data on disk using DETS,
allowing programs to work without continuous access to the Schema Registry.

Programs which use Kafka may process high message volumes, so efficiency
is important. They generally use multiple processes, typically one per
topic partition or more. On startup, each process may simultaneously attempt to
look up schemas.

The cache lookup runs in the caller's process, so it can run in parallel.
If there is a cache miss, then it calls the GenServer to update the cache.
This has the effect of serializing requests, ensuring that only one runs
at a time. See https://www.cogini.com/blog/avoiding-genserver-bottlenecks/ for
discussion.

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

### Timestamps

Avro timestamps are in Unix format with microsecond precision:

```elixir
iex> datetime = DateTime.utc_now()
~U[2019-11-08 09:09:01.055742Z]

iex> timestamp = AvroSchema.to_timestamp(datetime)
1573204141055742

iex> datetime = AvroSchema.to_datetime(timestamp)
~U[2019-11-08 09:09:01.055742Z]
```

# Contacts

I am `jakemorrison` on on the Elixir Slack and Discord, `reachfh` on Freenode
`#elixir-lang` IRC channel. Happy to chat or help with your projects.
