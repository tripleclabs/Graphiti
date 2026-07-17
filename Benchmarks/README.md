# Graphiti query execution benchmarks

Run the benchmarks in an optimized build:

```sh
swift run -c release graphiti-benchmarks
```

Useful options:

```text
--samples N       Measured batches per benchmark (default: 250)
--warmup N        Warm-up batches per benchmark (default: 25)
--items N         Objects returned by the list query (default: 100)
--concurrency N   Requests in each concurrent batch (default: 8)
--filter TEXT     Run benchmarks whose names contain TEXT
```

The suite intentionally separates two paths:

- `request.*` calls Graphiti's public `API.execute`. Each operation includes schema validation,
  parsing, document validation, variable coercion, execution, and result construction.
- `prepared.graphiti.*` uses Graphiti's public prepared-operation API to parse and validate once,
  then measures schema-bound execution and result construction. The `graphql-direct` control uses
  GraphQL's lower-level `execute` function directly.

The `graphql-direct` control uses an equivalent field defined directly with GraphQL. Compare it
with the corresponding Graphiti key-path benchmark to estimate the overhead of Graphiti's field
adapter independently of the rest of the GraphQL engine.

## Massive schema fixture

The benchmark target includes a generated Graphiti schema with 2,000 distinct object types and
five fields per type, for 10,000 model fields in total. The fixture is verified before measurements
begin. Its workloads compare a small and massive schema for:

- a trivial full request;
- a prepared hot query;
- concurrent prepared execution;
- selection and execution of one type from the massive schema;
- validation of an invalid type name; and
- full schema introspection.

The harness prints massive/small mean-latency ratios when both sides of a comparison are selected.
Prepared execution should ideally remain close to `1.0x`, because unrelated schema types should not
affect execution of an already validated operation.

Invalid-type validation defaults to at most 25 measured samples, and massive introspection defaults
to at most 10, because these deliberately expensive cases would otherwise dominate the suite. The
output's `n` column reports the actual sample count used for each row.

Regenerate the checked-in fixture after changing its shape:

```sh
swift Benchmarks/GenerateMassiveSchema.swift
```

The generated source is deliberately checked in so benchmark builds are reproducible and do not
require a build-tool plugin or source mutation during compilation.

Results are latency per operation. Concurrent benchmark latency is total batch duration divided by
the number of requests, so its `ops/s` column is the aggregate throughput of that batch rather than
individual request latency.

For useful comparisons, use the same machine, release toolchain, sample counts, and power settings.
Do not use debug-build results as a performance baseline.
