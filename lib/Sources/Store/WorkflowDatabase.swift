import Foundation
import SQLiteData

/// Creates or opens the SQLite database for a Workflow living at `directory`, applying the
/// schema idempotently. Re-opening an existing Workflow database is a no-op for already-applied
/// migrations, so this is safe to call on every launch.
public func openWorkflowDatabase(at directory: URL) throws -> any DatabaseWriter {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("workflow.sqlite").path
    let database = try defaultDatabase(path: path)
    var migrator = DatabaseMigrator()
    registerWorkflowMigrations(&migrator)
    try migrator.migrate(database)
    return database
}

func registerWorkflowMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Create per-Workflow schema") { db in
        try #sql(
            """
            CREATE TABLE "workflow" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "repoPath" TEXT NOT NULL DEFAULT '',
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "phase" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "workflowID" TEXT NOT NULL REFERENCES "workflow"("id") ON DELETE CASCADE,
              "kind" TEXT NOT NULL,
              "status" TEXT NOT NULL,
              "artifactPath" TEXT,
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "session" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "workflowID" TEXT NOT NULL REFERENCES "workflow"("id") ON DELETE CASCADE,
              "worktreePath" TEXT NOT NULL,
              "mode" TEXT NOT NULL,
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "turn" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "sessionID" TEXT NOT NULL REFERENCES "session"("id") ON DELETE CASCADE,
              "userPrompt" TEXT NOT NULL DEFAULT '',
              "finalAnswer" TEXT,
              "isError" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "durationMs" INTEGER,
              "costUSD" REAL,
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "content_block" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "turnID" TEXT NOT NULL REFERENCES "turn"("id") ON DELETE CASCADE,
              "position" INTEGER NOT NULL,
              "role" TEXT NOT NULL,
              "kind" TEXT NOT NULL,
              "text" TEXT NOT NULL DEFAULT '',
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(#"CREATE INDEX "index_phase_on_workflowID" ON "phase"("workflowID")"#)
            .execute(db)
        try #sql(#"CREATE INDEX "index_session_on_workflowID" ON "session"("workflowID")"#)
            .execute(db)
        try #sql(#"CREATE INDEX "index_turn_on_sessionID" ON "turn"("sessionID")"#)
            .execute(db)
        try #sql(#"CREATE INDEX "index_content_block_on_turnID" ON "content_block"("turnID")"#)
            .execute(db)
    }
}
