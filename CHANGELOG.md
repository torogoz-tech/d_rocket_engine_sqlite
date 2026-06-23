# Changelog

All notable changes to `d_rocket_engine_sqlite` are
documented in this file. Versions follow
[Semantic Versioning](https://semver.org/) and
**lockstep with `d_rocket`** — every
`d_rocket` release ships a paired
`d_rocket_engine_sqlite` release with the same
version number.

## [2.0.0] — 2026-06-17

Initial release. The SQLite engine is split out of
`d_rocket` core so consumers who only need
serialization, REST, or in-memory LINQ do not pay
for the `libsqlite3` native binding.

* **New package.** `d_rocket_engine_sqlite` is the
  SQLite implementation of d_rocket's `DbEngine`
  contract. Register it once at app startup with
  `dRocketSqlite()` and the
  `Db` / `DbContext` / `DbSet` / SQL `Queryable` /
  auto-migrations stack lights up.

* **Moved code from `d_rocket` core.** The
  `SqliteEngine`, `SqliteQueryProvider`, `Db`
  facade, encryption helpers, SQLCipher probe,
  SQL LINQ translator, and `Queryable<T>` SQL
  implementation all live here now. The
  `d_rocket` core package is engine-agnostic.

* **Required companion to d_rocket 2.0.** Any
  project that uses `Db` / `DbContext` / `DbSet` /
  `@Table` in d_rocket 2.0 must add
  `d_rocket_engine_sqlite` to its `pubspec.yaml`
  and call `dRocketSqlite.register()` before
  `Db.open` / `Db.inMemory`. Without it, the ORM
  throws a clear "no engine registered" error.
