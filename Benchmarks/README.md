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
- `prepared.*` parses and validates the document once, then measures execution and result
  construction through GraphQL's lower-level `execute` function.

The `graphql-direct` control uses an equivalent field defined directly with GraphQL. Compare it
with the corresponding Graphiti key-path benchmark to estimate the overhead of Graphiti's field
adapter independently of the rest of the GraphQL engine.

Results are latency per operation. Concurrent benchmark latency is total batch duration divided by
the number of requests, so its `ops/s` column is the aggregate throughput of that batch rather than
individual request latency.

For useful comparisons, use the same machine, release toolchain, sample counts, and power settings.
Do not use debug-build results as a performance baseline.
