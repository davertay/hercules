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

    migrator.registerMigration("Add toolName to content_block") { db in
        try #sql(
            """
            ALTER TABLE "content_block" ADD COLUMN "toolName" TEXT
            """
        )
        .execute(db)
    }

    // ADR 0005: tag each Session with the surface it serves so multiple Sessions can share one
    // Workflow database without their Turns bleeding together. Pre-existing rows predate the split
    // and could only have been Design's Session, so they default to `design`.
    migrator.registerMigration("Add kind to session") { db in
        try #sql(
            """
            ALTER TABLE "session" ADD COLUMN "kind" TEXT NOT NULL DEFAULT 'design'
            """
        )
        .execute(db)
    }

    // The Allocate Phase's structured Artifact: bite-size Issues carved out of the PRD and Design
    // summary, recorded as rows here rather than as a document. `dependencies` holds a JSON array of
    // the referenced per-Workflow `number`s — a distinct field, not a join table.
    migrator.registerMigration("Create issue table") { db in
        try #sql(
            """
            CREATE TABLE "issue" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "workflowID" TEXT NOT NULL REFERENCES "workflow"("id") ON DELETE CASCADE,
              "number" INTEGER NOT NULL,
              "title" TEXT NOT NULL DEFAULT '',
              "body" TEXT NOT NULL DEFAULT '',
              "dependencies" TEXT NOT NULL DEFAULT '[]',
              "status" TEXT NOT NULL DEFAULT 'new',
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL,
              "isDeleted" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(#"CREATE INDEX "index_issue_on_workflowID" ON "issue"("workflowID")"#)
            .execute(db)
    }
}
