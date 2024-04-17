# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2024-04-17
### Changed
- Update libs

## [0.3.0] - 2020-02-17
### Changed
- Pull in [erlavro 2.9.0](https://github.com/klarna/erlavro/compare/e43fe8b..cd49689) which encodes atom values as strings for string types

## [0.2.0] - 2020-02-05
### Changed
- Make `encode/2` return `{:ok, binary} | {:error, term()}` and add new `encode!/2`,
  https://github.com/cogini/avro_schema/pull/6
- Make `decode/2` return `{:ok, binary} | {:error, term()}` and add new `decode!/2`,
  https://github.com/cogini/avro_schema/pull/14
- Make `make_decoder/2` return maps as map type by default
  https://github.com/cogini/avro_schema/pull/13
- Make `make_decoder/2` decodes "null" schema types as `nil` by default by
  providing a decoder hook
  https://github.com/cogini/avro_schema/pull/16
- Encode nil values correctly for "null" schema types,
  https://github.com/cogini/avro_schema/pull/8
- Make `do_register_schema/3` private
- Rename `make_subject/1 and make_subject/2 to make_fp_subject/1 and make_fp_subject/2` to make name less generic

## [0.1.0] - 2019-12-31
### Added
- Initial release
