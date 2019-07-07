import 'dart:async';
import 'dart:mirrors';

import 'package:aqueduct/aqueduct.dart';
import 'package:aqueduct/src/cli/migration_source.dart';
import 'package:postgres/postgres.dart';
import 'package:isolate_executor/isolate_executor.dart';

class RunUpgradeExecutable extends Executable<Map<String, dynamic>> {
  RunUpgradeExecutable(Map<String, dynamic> message)
      : inputSchema = Schema.fromMap(message["schema"] as Map<String, dynamic>),
        dbInfo = DBInfo.fromMap(message["dbInfo"] as Map<String, dynamic>),
        sources = (message["migrations"] as List<Map>)
            .map((m) => MigrationSource.fromMap(m as Map<String, dynamic>))
            .toList(),
        currentVersion = message["currentVersion"] as int,
        super(message);

  RunUpgradeExecutable.input(
      this.inputSchema, this.dbInfo, this.sources, this.currentVersion)
      : super({
          "schema": inputSchema.asMap(),
          "dbInfo": dbInfo.asMap(),
          "migrations": sources.map((source) => source.asMap()).toList(),
          "currentVersion": currentVersion
        });

  final Schema inputSchema;
  final DBInfo dbInfo;
  final List<MigrationSource> sources;
  final int currentVersion;

  @override
  Future<Map<String, dynamic>> execute() async {
    hierarchicalLoggingEnabled = true;

    PostgreSQLPersistentStore.logger.level = Level.ALL;
    PostgreSQLPersistentStore.logger.onRecord
        .listen((r) => log("${r.message}"));

    PersistentStore store;
    if (dbInfo != null && dbInfo.flavor == "postgres") {
      store = PostgreSQLPersistentStore(dbInfo.username, dbInfo.password,
          dbInfo.host, dbInfo.port, dbInfo.databaseName,
          timeZone: dbInfo.timeZone);
    }

    var migrationTypes = currentMirrorSystem()
        .isolate
        .rootLibrary
        .declarations
        .values
        .where((dm) =>
            dm is ClassMirror && dm.isSubclassOf(reflectClass(Migration)));

    final instances = sources.map((s) {
      final type = migrationTypes.firstWhere((cm) {
        return cm is ClassMirror &&
            MirrorSystem.getName(cm.simpleName) == s.name;
      }) as ClassMirror;
      final migration =
          type.newInstance(const Symbol(""), []).reflectee as Migration;
      migration.version = s.versionNumber;
      return migration;
    }).toList();

    try {
      final updatedSchema = await store.upgrade(inputSchema, instances);
      await store.close();

      return updatedSchema.asMap();
    } on QueryException catch (e) {
      if (e.event == QueryExceptionEvent.transport) {
        final databaseUrl = "${dbInfo.username}:${dbInfo.password}@${dbInfo.host}:${dbInfo.port}/${dbInfo.databaseName}";
        return {"error": "There was an error connecting to the database '$databaseUrl'. Reason: ${e.message}."};
      }

      rethrow;
    } on MigrationException catch (e) {
      return {"error": e.message};
    } on SchemaException catch (e) {
      return {"error": "There was an issue with the schema generated by a migration file. Reason: ${e.message}"};
    } on PostgreSQLException catch (e) {
      if (e.severity == PostgreSQLSeverity.error && e.message.contains("contains null values")) {
        return {"error": "There was an issue when adding or altering column '${e.tableName}.${e.columnName}'. "
          "This column cannot be null, but there already exist rows that would violate this constraint. "
          "Use 'unencodedInitialValue' in your migration file to provide a value for any existing columns."};
      }

      return {"error": "There was an issue. Reason: ${e.message}. Table: ${e.tableName} Column: ${e.columnName}"};
    }
  }

  static List<String> get imports => [
        "package:aqueduct/aqueduct.dart",
        "package:logging/logging.dart",
        "package:postgres/postgres.dart",
        "package:aqueduct/src/cli/migration_source.dart",
        "package:aqueduct/src/runtime/runtime.dart"
      ];
}

class DBInfo {
  DBInfo(this.flavor, this.username, this.password, this.host, this.port,
      this.databaseName, this.timeZone);

  DBInfo.fromMap(Map<String, dynamic> map)
      : flavor = map["flavor"] as String,
        username = map["username"] as String,
        password = map["password"] as String,
        host = map["host"] as String,
        port = map["port"] as int,
        databaseName = map["databaseName"] as String,
        timeZone = map["timeZone"] as String;

  final String flavor;
  final String username;
  final String password;
  final String host;
  final int port;
  final String databaseName;
  final String timeZone;

  Map<String, dynamic> asMap() {
    return {
      "flavor": flavor,
      "username": username,
      "password": password,
      "host": host,
      "port": port,
      "databaseName": databaseName,
      "timeZone": timeZone
    };
  }
}
