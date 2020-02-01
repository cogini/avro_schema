# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Make `encode/2` return `{:ok, binary} | {:error, term()}` and add new `encode!/2`,
  https://github.com/cogini/avro_schema/pull/6
- Make `make_decoder/2` return maps as map type by default
- Encode nil values correctly for :null schema types,
  https://github.com/cogini/avro_schema/pull/8

## [0.1.0] - 2019-12-31
### Added
- Initial release
